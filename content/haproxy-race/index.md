+++
title = "The Great Proxy Race"
author = "Josh Robson Chase"
date = 2024-02-13T14:05:00-05:00
draft = true
[taxonomies]
tags = ["c", "haproxy", "concurrency"]
+++

A cautionary tale about concurrent programming in C (and really _most_
languages), and why it's difficult.

<!-- more -->

# Background

From [Wikipedia](https://en.wikipedia.org/wiki/HAProxy):

> HAProxy is a free and open source software that provides a high availability
> load balancer and reverse proxy for TCP and HTTP-based applications that
> spreads requests across multiple servers. It is written in C and has a
> reputation for being fast and efficient (in terms of processor and memory
> usage).

As a single-purpose load-balancer, it presents an attractive alternative to web
servers such as nginx and Apache httpd which _also_ provide load-balancer and
reverse proxy capabilities. As such, it's been adopted by several well-known
sites, including (also from Wikipedia) GoDaddy, GitHub, Bitbucket, Stack
Overflow, Reddit, Slack, Speedtest.net, Tumblr, Twitter and Tuenti and is used
in the OpsWorks product from Amazon Web Services.

Its support for plain TCP services via its
[PROXY Protocol](https://www.haproxy.org/download/1.8/doc/proxy-protocol.txt)
(which has become a de-facto standard) allows it to act as a load-balancer for a
wide variety of applications outside of the various flavors of HTTP.

It should come as no great surprise that we have also adopted HAProxy at ngrok!
It provides the load-balancing frontend to our agent endpoints, evenly
distributing plain TCP connections among our agent servers. These connections
differ from more commonly-proxied HTTP requests in a few crucial ways:

1. They're truly _connection_ oriented rather than _request_ oriented as with
   HTTP. An HTTP load-balancer may choose to map requests to backend services
   however it pleases (within reason). Several requests over a single
   load-balancer connection may get sent to the backend via multiple backend
   connections, or requests over multiple load-balancer connections could get
   consolidated to a single backend connection.

   In contrast, our agent load-balancer connections are mapped to backend
   service connections 1:1.

2. Retries are _hard_. So hard that they aren't really a thing from the agent's
   perspective. The request-oriented nature of HTTP means that load balancers
   can react to backend connections being closed mid-request by simply opening a
   new connection (either to the same backend server or a different one), and
   re-attempt the request without the client needing to be aware of it.

   At this point in the lifecycle of an agent connection, however, specifics of
   the protocol used by the streams within the agent connection are nonexistent;
   they're effectively _all_ plain byte streams. While these streams could
   theoretically be interrupted and resumed on a different agent server, it's a
   hard enogh problem that we've elected not to solve it for now, and instead
   trust clients connecting to the ngrok edge to implement retries at a higher
   protocol level instead.

3. Connection cost is highly front-loaded. With HTTP, each request may be
   equally expensive, but the cost of opening a new backend connection to start
   sending requests is cheap.

   Agent connections do most of their work up-front. When an agent connects, it
   always starts by sending an `Auth` request, followed by some number of `Bind`
   requests for each configured forwarder. Each of these transits multiple other
   internal services to validate/compile configurations, synchronize state to
   our edge servers, etc. At "runtime" though, agent connections are, by and
   large, simple byte copies.

The implication of these differences is that we try to be as nice to our agents
as we can. Connections should be allowed to live as long as they want, since a
connection being dropped means that all streams currently transiting it will be
interrupted. If an agent _does_ lose its connection for whatever reason, it will
attempt to reconnect as soon as possible[^a] to minimize downtime.

While we want to be nice to the agents, we also need to protect ourselves.
Because agents will immediately attempt to reconnect, a server crashing
unexpectedly could cause a stampeding herd of reconnects. Since agent
connections are front-loaded and involve multiple services, these herds have the
potential to cause serious disruption. Luckily, HAProxy has a nice
[rate-limit sessions](https://www.haproxy.com/documentation/haproxy-configuration-manual/latest/#4-rate-limit%20sessions)
option which puts a cap on the number of new connections it will accept per
second.

<!-- prettier-ignore -->
[^a]: There's some builtin backoff in to protect us, but it can't always be trusted in the event that an external process is restarting the agent.

# Timeline of Events

Around the beginning of the year, we started rolling out new restrictions on the
versions of the ngrok agent that would be allowed to connect[^2]. This was in an
effort to lower the support burden for old agents and to get rid of old protocol
cruft. These restrictions made it such that attempting an initial connection
with an old agent resulted in an immediate error and process exit. _Already
running_ agents, however, would be allowed to remain connected until a reconnect
was forced either by their network or by our generous drain process. Due to the
way the agent was written at the time, it would continue attempting to reconnect
until the process was terminated. We also had little control over agents being
restarted by external processes like the host's service manager. All of this was
well-known and expected, and we were confident that our backend services could
handle the increased load, especially since we were able to short-circuit early
in the connection process and skip the most expensive parts.

During the course of an unrelated incident investigation, we decided to drop
support for a particular version of the agent that represented an unusually high
proportion of our load a little ahead of schedule[^3] in attempt to shed some
load. Things seemed to be going smoothly, and we were handling the increase in
reconnect attempts without issue.

Over the next week, we started seeing large spikes of agent reconnects with
increasing frequency. Each time this occurred, it caused a minor disruption as
the herd of agents reconnected, but which never escalated to the point of
getting someone out of bed since things tended to settle out in a few minutes.
Customers who had their agents unexpectedly disconnected were definitely seeing
impact though, and it cast enough of a shadow over our plans to drop support for
_more_ agent versions that it warranted a deeper investigation.

To our surprise, it wasn't in fact our services causing the flood of reconnects,
but HAProxy itself! It took a few of us puzzling over service graphs for a while
before someone noticed that the spikes coincided with restarts of the HAProxy
service[^4]. We had taken it for granted as something that "Just Works" and had
initially overlooked it.

All of the previous-container logs told the same story:

```bash
FATAL: bug condition "task->expire == 0" matched at src/task.c:285
  call trace(11):
  |       0x56eb28 [0f 0b 66 0f 1f 44 00 00]: __task_queue+0xc8/0xca
  |       0x553903 [eb 9c 0f 1f 00 ba 03 00]: main+0x1317e3
  |       0x556de6 [8b 54 24 18 85 d2 0f 84]: listener_accept+0x12c6/0x14f6
  |       0x5ac348 [4d 8b 3c 24 49 01 df 64]: fd_update_events+0x1a8/0x4a8
  |       0x427d58 [48 39 eb 74 3b 66 66 66]: main+0x5c38
  |       0x53801f [64 48 8b 04 25 00 00 00]: run_poll_loop+0x10f/0x647
  |       0x5387f5 [49 c7 c4 c0 47 6a 00 49]: main+0x1166d5
  | 0x7f7f662b4333 [e9 74 fe ff ff 48 8b 44]: libc:+0x8b333
  | 0x7f7f66336efc [48 89 c7 b8 3c 00 00 00]: libc:+0x10defc
```

At this point, we realized that the situation was Not Good. You never want to
doubt the reliability of a critical piece of infrastructure, especially one that
you don't maintain yourself.

<!-- prettier-ignore -->
[^2]: Free-tier only - paid users were safe.

<!-- prettier-ignore -->
[^3]: Earlier in our internal rollout schedule, but still after we said we were dropping support.

<!-- prettier-ignore -->
[^4]: In retrospect, we should've had better alerting around this.

# Analysis and Fix

TODO

## HAProxy Internals

TODO

## Reproducing

TODO

## Synchronization

TODO

## Verification

TODO
