#!/usr/bin/env ruby
# vim:encoding=UTF-8:

require 'rubygems'
require 'net/irc'
require 'xmpp4r'
require 'xmpp4r/muc'

require 'set'

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
    @muc_objects = {}
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

    return unless @prefix # We have a prefix if we've gone through on_user

    old_prefix = @prefix
    @prefix = Prefix.new "#{@nick}!#{@prefix.user}@#{@prefix.host}"

    if @muc_objects.empty?
      post old_prefix, NICK, @nick
    else
      @muc_objects.each do |room, objects|
        objects[:muc_client].nick = @nick if objects[:muc_client]
      end
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

      if @muc_objects[chan_name]
        return
      else
        @muc_objects[chan_name] = {}
      end

      @muc_objects[chan_name][:fake_joins] = Set.new

      muc_client = Jabber::MUC::SimpleMUCClient.new @client
      muc_client.on_message do |time, nick, text|
        chan, prefix, _ = jabber_presence_to_irc muc_client.roster[nick]
        post prefix, PRIVMSG, chan, text unless nick == @nick.downcase
        false
      end
      muc_client.on_room_message do |time, text|
        @log.debug text
      end

      ## Add leave callback
      muc_client.add_leave_callback(50) do |presence|
        _ , prefix, _ = jabber_presence_to_irc presence

        if presence.x(Jabber::MUC::XMUCUser)
          if presence.x.status_code == 303
            # Not a real leave, just a nick change.
            old_jid = Jabber::JID.new presence.from
            old_prefix = "#{old_jid.resource}!#{old_jid.strip}"
            new_nick = presence.x(Jabber::MUC::XMUCUser).items.first.nick

            post old_prefix, NICK, new_nick

            # Make sure the next presence isn't treated as a join
            new_jid = old_jid
            new_jid.resource = new_nick
            @muc_objects[chan_name][:fake_joins] << new_jid
          end
        end

        false
      end

      ## Add join callback
      muc_client.add_join_callback(50) do |presence|
        jid = Jabber::JID.new presence.from
        if @muc_objects[chan_name][:fake_joins].include? jid
          # If the remote user changed nick, we will see a join but we
          # must not treat it as a real join, just silently swallow it.
          @muc_objects[chan_name][:fake_joins].delete jid
        else
          chan, prefix, _ = jabber_presence_to_irc presence
          post prefix, JOIN, chan
        end

        false
      end


      begin
        muc_client.join(real_jid)
      rescue Jabber::ServerError => e
        xmlError = e.error
        if xmlError.error == 'conflict' && xmlError.type == :cancel
          # Nick conflict
          post server_name, ERR_NICKNAMEINUSE, @nick, "Nickname is already in use"
        else
          @log.debug "ERROR: Couldn't decode jabber error from server after join attempt: #{e.error}"
        end

        @muc_objects.delete chan_name
        return
      end

      # join success !
      # TODO: send topic
      irc_nicks_and_roles = []
      muc_client.roster.each do |nick, presence|
        chan, prefix, irc_nick_and_role = jabber_presence_to_irc presence
        irc_nicks_and_roles << irc_nick_and_role

        post prefix, JOIN, chan if nick == @nick
      end

      post server_name, RPL_NAMREPLY, @nick, "=", chan_name, irc_nicks_and_roles.join(" ").strip
      post server_name, RPL_ENDOFNAMES, @nick, chan_name, "End of /NAMES list"

      @muc_objects[chan_name][:muc_client] = muc_client
    end
	end

  def on_part(m); part_room(m) end

	def on_quit(m); part_room(m) end

  ##
  # Leave a room.
  #
  # This method will be used for both on_part and on_quit, since they
  # are very similar.
  def part_room(message)
		channel, message = *message.params

    if @muc_objects.keys.include? channel
      # Part from jabber..
      muc_client = @muc_objects[channel][:muc_client]
      muc_client.exit message
      @muc_objects.delete channel

      # .. and announce it to IRC
      post @prefix, PART, channel, message
    else
			post server_name, ERR_NOSUCHCHANNEL, channel, "No such nick/channel"
    end
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
    target, message = *m.params

    if @muc_objects.keys.include? target
      muc_client = @muc_objects[target][:muc_client]
      muc_client.say message
    else
			post server_name, ERR_NOSUCHNICK, @nick, target, "No such nick/channel"
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
    if presence.x(Jabber::MUC::XMUCUser) and item = presence.x(Jabber::MUC::XMUCUser).items.first

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

