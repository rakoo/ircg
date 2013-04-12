ircg, the IRC to Jabber MUC gateway.

# Description

ircg is a gateway from IRC to Jabber MUCs. Connect with your traditional
IRC client (irrsi, weechat, ...) and access transparently to Jabber
MUCs.

# Status

Basic functionality :

- USER
- NICK
- JOIN
- PRIVMSG
- PART
- QUIT
- WHO

in short, you can connect and join a room.

# Details

ircg accepts IRC connections from anyone. When a client connects to it,
a Jabber MUC client is created and associated to the IRC client.
This Jabber client is in charge of communicating with the MUC and
transferring the messages, status, etc from/to the IRC client. All the
shared status (nick, state, participants...) is managed by the MUC;
there is no logic in ircg.

Because we need to create Jabber clients on-the-fly, they are anonymous
clients, as per defined in XEP-0175 (http://xmpp.org/extensions/xep-0175.html).
As such, they shouldn't have more privilege than participant (if they
were moderator, and the client disconnected, we would have a stall,
dead moderator waiting in the room).

As a consequence of this, IRC clients cannot connect to anything but
the domain they are in. I am running an "anonymous node" on
`anonymous.otokar.looc2011.eu`, so the anonymous clients created from it
may only connect to the resources under the `otokar.looc2011.eu` domain.
Anonymous clients connecting to external domains could be considered as
spam, so it's a bad idea to try it.

# Demo

It may not be running continuously, but if it is, you may try to
IRC-connect to

```
#ircg on conference.otokar.looc2011.eu:6969
```

This will connect you to the Jabber MUC

```
ircg@conference.otokar.looc2011
```

which you can also freely join, of course. Do remember that all this is
experimental, though

# Dependencies

- xmpp4r
- net-irc

# Install/run

$ gem install xmpp4r net-irc
$ ruby ircg.rb

# License

CC0 (http://creativecommons.org/publicdomain/zero/1.0/)
