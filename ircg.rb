#!/usr/bin/env ruby
# vim:encoding=UTF-8:

require 'rubygems'
require 'net/irc'
require 'xmpp4r'
require 'xmpp4r/muc'

ANON_PROVIDER = 'anon.otokar.looc2011.eu'
AUTHORIZED_CONFERENCE_DOMAIN = 'conference.otokar.looc2011.eu'

class NetIrcGatewayServer < Net::IRC::Server::Session
	def server_name
		"irc-gateway"
	end

	def server_version
		"0.0.0"
	end

	def available_user_modes
		""
	end

	def default_user_modes
		""
	end

	def available_channel_modes
		""
	end

	def default_channel_modes
		""
	end

	def initialize(*args)
		super
    @muc_clients = {}
	end

	def on_pass(m)
	end

	def on_user(m)
		@user, @real = m.params[0], m.params[3]
		@host        = @socket.peeraddr[2]
		@prefix      = Prefix.new("#{@nick}!#{@user}@#{@host}")
		@joined_on   = @updated_on = Time.now.to_i

    ## Only one nick for all the rooms for the moment
    ## TODO: one nick per room
    anon_jid = Jabber::JID.new ANON_PROVIDER
    @client = Jabber::Client.new anon_jid
    @client.connect
    @client.auth_anonymous


    post @prefix, NICK, @nick

    initial_message
    start_ping
	end

  def on_nick(m)
    @nick = m.params[0]

    @muc_clients.each do |room, client|
      client.nick = @nick if client
    end
  end

	def on_join(m)
		channels = m.params[0].split(/\s*,\s*/)
    channels.each do |channel|

      jided = Jabber::JID.new channel

      # If channel is #chan@domain.tld, jided.node is #chan and
      # jided.domain is domain.tld.
      #
      # If channel is #chan, jided.node is None and jided.domain is
      # #chan

      if jided.node

        if jided.domain != AUTHORIZED_CONFERENCE_DOMAIN
          @log.debug "; Trying to join #{jided.domain}, forbidden"
          post server_name, ERR_NOSUCHCHANNEL, @nick, channel, "No such channel"
          return true
        end

        chan_name = jided.node
      else
        chan_name = jided.domain
      end

      real_jid = Jabber::JID.new chan_name.sub(/^#/, ''), AUTHORIZED_CONFERENCE_DOMAIN, @nick

      if @muc_clients[real_jid]
        return @muc_clients[real_jid]
      end

      muc_client = Jabber::MUC::SimpleMUCClient.new @client
      muc_client.on_message do |time, nick, text|
        post server_name, PRIVMSG, nick, message unless nick == @nick.downcase
      end
      muc_client.on_room_message do |time, text|
        @log.debug text
      end

      ## Add join callback
      muc_client.add_join_callback(1) do |presence|
        chan, prefix = jabber_presence_to_irc presence
        post prefix, JOIN, chan
      end

      muc_client.join(real_jid)

      # join success !
      irc_nicks_and_roles = []
      muc_client.roster.each do |nick, presence|
        chan, prefix, irc_nick_and_role = jabber_presence_to_irc presence
        irc_nicks_and_roles << irc_nick_and_role

        post prefix, JOIN, chan if nick == @nick
      end

      post server_name, RPL_NAMREPLY, @nick, "=", chan_name, irc_nicks_and_roles.join(" ").strip
      post server_name, RPL_ENDOFNAMES, @nick, chan_name, "End of /NAMES list"

      @muc_clients[real_jid] = muc_client
    end
	end

	def on_part(m)
		channel, message = *m.params

		@@channels[channel.downcase][:users].each do |nick, f|
			post @@users[nick][:socket], @prefix, PART, @@channels[channel.downcase][:alias], message
		end
		channel_part(channel)
	end

	def on_quit(m)
		message = m.params[0]
		@@channels.each do |channel, f|
			if f[:users].key?(@nick.downcase)
				channel_part(channel)
				f[:users].each do |nick, m|
					post @@users[nick][:socket], @prefix, QUIT, message
				end
			end
		end
		finish
	end

	def on_disconnected
    raise
		super
		@@channels.each do |channel, f|
			if f[:users].key?(@nick.downcase)
				channel_part(channel)
				f[:users].each do |nick, m|
					post @@users[nick][:socket], @prefix, QUIT, "disconnect"
				end
			end
		end
		channel_part_all
		@@users.delete(@nick.downcase)
	end

	def on_who(m)
		channel = m.params[0]
		return unless channel

		c = channel.downcase
		case
		when @@channels.key?(c)
			@@channels[c][:users].each do |nickname, m|
				nick = @@users[nickname][:nick]
				user = @@users[nickname][:user]
				host = @@users[nickname][:host]
				real = @@users[nickname][:real]
				case
				when m.index("@")
					f = "@"
				when m.index("+")
					f = "+"
				else
					f = ""
				end
				post @socket, server_name, RPL_WHOREPLY, @nick, @@channels[c][:alias], user, host, server_name, nick, "H#{f}", "0 #{real}"
			end
			post @socket, server_name, RPL_ENDOFWHO, @nick, @@channels[c][:alias], "End of /WHO list"
		end
	end

	def on_mode(m)
	end

	def on_privmsg(m)
		while (Time.now.to_i - @updated_on < 2)
			sleep 2
		end
		idle_update

		return on_ctcp(m[0], ctcp_decoding(m[1])) if m.ctcp?

		target, message = *m.params
		t = target.downcase

		case
		when @@channels.key?(t)
			if @@channels[t][:users].key?(@nick.downcase)
				@@channels[t][:users].each do |nick, m|
					post @@users[nick][:socket], @prefix, PRIVMSG, @@channels[t][:alias], message unless nick == @nick.downcase
				end
			else
				post @socket, nil, ERR_CANNOTSENDTOCHAN, @nick, target, "Cannot send to channel"
			end
		when @@users.key?(t)
			post @@users[nick][:socket], @prefix, PRIVMSG, @@users[t][:nick], message
		else
			post @socket, nil, ERR_NOSUCHNICK, @nick, target, "No such nick/channel"
		end
	end

	def on_ping(m)
		post server_name, PONG, m.params[0]
	end

	def on_pong(m)
		@ping = true
	end

	def idle_update
		@updated_on = Time.now.to_i
		if logged_in?
			@@users[@nick.downcase][:updated_on] = @updated_on
		end
	end

	def channel_create(channel)
		@@channels[channel.downcase] = {
			:alias      => channel,
			:topic      => "",
			:mode       => default_channel_modes,
			:users      => {@nick.downcase => ["@"]},
		}
	end

	def channel_part(channel)
		@@channels[channel.downcase][:users].delete(@nick.downcase)
		channel_delete(channel.downcase) if @@channels[channel.downcase][:users].size == 0
	end

	def channel_part_all
		@@channels.each do |c|
			channel_part(c)
		end
	end

	def channel_delete(channel)
		@@channels.delete(channel.downcase)
	end

	def start_ping
		Thread.start do
			loop do
				@ping = false
				time = Time.now.to_i
				if @ping == false && (time - @updated_on > 60)
					post server_name, PING, @prefix
					loop do
						sleep 1
						if @ping
							break
						end
						if 60 < Time.now.to_i - time
							Thread.stop
							finish
						end
					end
				end
				sleep 60
			end
		end
	end

	# Call when client connected.
	# Send RPL_WELCOME sequence. If you want to customize, override this method at subclass.
	def initial_message
		post server_name, RPL_WELCOME,  @nick, "Welcome to the Internet Relay Network #{@prefix}"
		post server_name, RPL_YOURHOST, @nick, "Your host is #{server_name}, running version #{server_version}"
		post server_name, RPL_CREATED,  @nick, "This server was created #{Time.now}"
		post server_name, RPL_MYINFO,   @nick, "#{server_name} #{server_version} #{available_user_modes} #{available_channel_modes}"
	end

  private

  def jabber_presence_to_irc presence
    x = presence.get_elements('x').first
    if x.kind_of? Jabber::MUC::XMUCUser
      item = x.items.first

      # in most cases, item.role is 'moderator' or 'participant'
      irc_role = item.role == 'moderator' ? '@' : ''

      # We try to get the participants' jid. If the room is
      # semy-anonymous, it isn absent; fall back to the room's jid
      participant_jid = Jabber::JID.new(item.jid ? item.jid : presence.from).strip
    end

    room_jid = Jabber::JID.new presence.from
    irc_nick = room_jid.resource
    irc_nick_and_role = "#{irc_role}#{irc_nick}"

    chan = "##{room_jid.node}" # Only public chans for the moment
    prefix = "#{irc_nick}!#{participant_jid}"

    [chan || "", prefix || "", irc_nick_and_role]
  end

end


if __FILE__ == $0
	require "optparse"

	opts = {
		:port  => 6969,
		:host  => "localhost",
		:log   => nil,
		:debug => false,
		:foreground => false,
	}

	OptionParser.new do |parser|
		parser.instance_eval do
			self.banner = <<-EOB.gsub(/^\t+/, "")
				Usage: #{$0} [opts]

			EOB

			separator ""

			separator "Options:"
			on("-p", "--port [PORT=#{opts[:port]}]", "port number to listen") do |port|
				opts[:port] = port
			end

			on("-h", "--host [HOST=#{opts[:host]}]", "host name or IP address to listen") do |host|
				opts[:host] = host
			end

			on("-l", "--log LOG", "log file") do |log|
				opts[:log] = log
			end

			on("--debug", "Enable debug mode") do |debug|
				opts[:log]   = $stdout
				opts[:debug] = true
			end

			on("-f", "--foreground", "run foreground") do |foreground|
				opts[:log]        = $stdout
				opts[:foreground] = true
			end

			on("-n", "--name [user name or email address]") do |name|
				opts[:name] = name
			end

			parse!(ARGV)
		end
	end

	opts[:logger] = Logger.new(opts[:log], "daily")
	opts[:logger].level = opts[:debug] ? Logger::DEBUG : Logger::INFO

	#def daemonize(foreground = false)
	#	[:INT, :TERM, :HUP].each do |sig|
	#		Signal.trap sig, "EXIT"
	#	end
	#	return yield if $DEBUG or foreground
	#	Process.fork do
	#		Process.setsid
	#		Dir.chdir "/"
	#		STDIN.reopen  "/dev/null"
	#		STDOUT.reopen "/dev/null", "a"
	#		STDERR.reopen STDOUT
	#		yield
	#	end
	#	exit! 0
	#end

	#daemonize(opts[:debug] || opts[:foreground]) do
	Net::IRC::Server.new(opts[:host], opts[:port], NetIrcGatewayServer, opts).start
	#end
end

