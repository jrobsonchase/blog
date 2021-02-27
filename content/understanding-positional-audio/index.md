+++
title = "Understanding Mumble Positional Audio"
author = "Josh Robson Chase"
date = 2021-02-27T16:00:00-05:00
[taxonomies]
tags = ["mumble", "golang"]
+++

In my [last post][lastpost], I discussed some of the process of building a
mod for Valheim that adds support for Mumble Positional Audio. During the
process of helping some users troubleshoot, it became clear that it's not a
terribly well understood system, and Mumble itself doesn't offer much
feedback on what's actually going on. Where each bit of data is available and
processed isn't obvious, and can lead to misconceptions about how things
work.

[lastpost]: ../valheim-mumble

<!-- more -->

# System Overview

There are five main types of data at play in the positional audio system:

* ID: Unique identifier for each player. Might contain additional information
  (team, role, etc.)
* Context: Used to determine if two players should get positional audio from
  each other. Same context: Audio is positional. Different contexts: Audio is
  normal. This is always a two-way street. Either both players get positional
  audio, or neither does.
* Location: Your location in-game
* Heading: The direction you're facing
* Audio: Your voice picked up by your mic

Likewise, there are five types of actors in play:

* The Game: This provides data to the mumble client, either via built-in
  support for the Mumble Link protocol or via a Mumble plugin that snoops on
  its memory.
* The local Mumble client: The Mumble client running on the same computer as
  your game.
* Murmur: The mumble server. Gets input from each client and distributes it to
  the others.
* Other clients with the same Context
* Other clients with different Contexts

Not all of the data is available to all of the actors though, which can be
surprising in some cases. The Game provides the ID, Context, Location, and
Heading to the Mumble Client. Of these, the Heading is omitted from the data
sent to Murmur. Why is that? Doesn't the server need to have all of the
location and heading information from each client to change the audio to
sound directional. It would, if that processing actually occurred on the
server.

Instead, that processing is done completely client-side in Mumble.
This makes a lot of sense. With N clients there are N<sup>2</sup> - N streams
to calculate the position of - for each client, there's one for every other
client but itself. This would scale poorly and would require a much more
powerful server.

Since the server doesn't calculate the position of the audio streams, each
client needs to get the positional information for each audio stream. This is
where the Context comes in. The ID and Context for each client is kept on the
server and is not sent to the other clients. The server uses the Context to
decide which clients need to receive positional information along with the
audio streams from other clients. From your local Mumble's perspective, the
audio stream from every user with the same Context will contain positional
information. The audio streams from users with a different context will have
no position attached.

{{ image(path="diagram.png", alt="Dataflow among components") }}

# Implications

* The only thing that's different between positional audio streams is the
  inclusion of a location in each audio packet.
* Every client always receives all of the audio.
* The decision around what can and can't be heard is made in the Mumble client
  based solely on the relative position of the stream.
* The audio and position data sent to each client with the same Context is
  identical. Either positional audio works for everyone in the group, or it
  works for no one. Any differences in user experience comes down to the
  Mumble client and its configuration.

# When Things Go Wrong

If things aren't working the way you expect them to, the first step is
gathering the data and making sure that the state of things is correct.
Unfortunately, I haven't found a way to instruct either the Mumble client or
server to include any relevant information in their logs. The best way I've
found to get it all is with a combination of a dummy client and a management
connection to the server.

The dummy client is fairly straightforward. There are a number of libraries
that can initiate a connection to Murmur and pretend to be a Mumble client.
The [Mumble wiki][wiki] has a good list of client libraries. Once connected,
they can receive everything a normal client can. For us, the most important
thing here is the position data.

[wiki]: https://wiki.mumble.info/wiki/3rd_Party_Applications#Libraries

The server management connection can go a couple of ways. There's an older
interface that uses [ICE][ice] as its protocol. There's also a newer
experimental interface that uses GRPC, which I just so happen to have some
actual experience with.

[ice]: https://en.wikipedia.org/wiki/Internet_Communications_Engine

Armed with a list of libraries and the [GRPC definition][grpc], the only
thing left to do was to write a utility that could combine data from both
sources. The [end result][debugtool] was pretty simple and gives a much
clearer picture of what's happening with regards to positional audio.

[grpc]: https://raw.githubusercontent.com/mumble-voip/mumble/master/src/murmur/MurmurRPC.proto
[debugtool]: https://gitlab.com/jrobsonchase/mumble-position-debug

```
./mumble-position-debug -chan Valheim -pass password
2021/02/27 15:04:21 joshtest: id: "Agent47", context: "Manual placement\x00Mumble"
2021/02/27 15:04:21 debug: id: "debug", context: "Manual placement\x00Mumble"
2021/02/27 15:04:27 joshtest: -48.85 0 -133.85
2021/02/27 15:04:40 joshtest: id: "Agent47", context: "Manual placement\x00Something Else"
2021/02/27 15:04:43 joshtest: no position data
2021/02/27 15:04:56 joshtest: id: "Agent47", context: "Manual placement\x00Mumble"
2021/02/27 15:04:58 joshtest: -48.85 0 -133.85
2021/02/27 15:05:01 joshtest: 70.77 0 -21.54
```

The "debug" user is the debug client and "joshtest" is a real Mumble
connection using the "Manual placement" plugin. One interesting thing I
learned in the process is that the Mumble client includes the name of the
game in the Context, so *both* need to match. While this can't help if the
issue is in the Mumble client itself, it can at least be used to determine if
all of the relevant data is getting to where it needs to be, which helps
narrow things down.
