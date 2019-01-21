+++
title = "Embedded Rust Frustrations"
author = "Josh Robson Chase"
date = 2019-01-21T15:00:00-05:00
draft = true
[taxonomies]
tags = ["rust", "embedded", "async", "futures"]
+++

Part 2 of my custom keyboard project!

I didn't mean for this to become its own post, but it kind of got away from
me. I've had a blast getting my feet wet in embedded dev so far with Rust,
but it hasn't been without its share of headaches. I'm sure most of my
problems can be attributed to my lack of experience in this realm, but
hopefully I'll be able to turn my frustrations into something interesting by
parts 3 and 4!

Part 1 can be found here: [Bootstrapping My Embedded Rust Development
Environment](../embedded-bootstrapping/)

<!-- more -->

## Existing Libraries

In the process of exploring my options for building the firmware for my
keyboard , I've seen a *ton* of awesome stuff from the embedded working
group. In particular, I've been quite pleased with the support for the
STM32F103 family of boards, and for Cortex-M boards in general.
Unfortunately, support for asynchronous programming seems to be a bit
lacking, especially in the [embedded-hal] implementations such as
[stm32f103xx-hal]. While most of the HAL traits return the [nb::Error] type,
which can have a `WouldBlock` variant, the main way to work with these
interfaces is simply to poll them until they quit blocking, which is less
than ideal.

[nb::Error]: https://docs.rs/nb/0.1.1/nb/enum.Error.html
[stm32f103xx-hal]: https://github.com/japaric/stm32f103xx-hal
[embedded-hal]: https://docs.rs/embedded-hal

### HAL Interrupt Frustrations

While there's some interrupt support in the `embedded-hal` world,
it's not quite there yet. For example, the [stm32f103xx_hal::serial::Serial][Serial]
type has a `listen` method that can be used to enable/disable the "receive
register not empty" (RXNE) and the "transmit register empty" (TXE)
interrupts. The problem is that, in order to be used for actual IO, the
`Serial` struct has to be `split()` into `Tx`/`Rx` parts, which consumes it
and makes the `listen` method unavailable. This presents a problem because
the TXE interrupt will fire *continuously* until its disabled. From my
understanding, the intended way for the interrupt to be used is to only
enable it while there's buffered data to be transmitted, and then disable it
once everything has been written. This doesn't appear to be possible with the
current HAL interface. Also, the interrupt handlers aren't defined by the HAL
crate, so they're left to users of the library to implement and carefully
plumb with `static`s to interact with the other parts of the firmware.

[Serial]: https://japaric.github.io/stm32f103xx-hal/stm32f103xx_hal/serial/struct.Serial.html

### RTFM

I should also mention [RTFM]. RTFM is a framework for building real-time
embedded systems, with a focus on interrupt-driven flow control. It's got a
really cool system of hardware tasks (interrupts) and software tasks that can
be assigned different priority levels, which allows resources to be shared
safely and without critical sections if no preemption is possible. My biggest
concerns with it are how macro-heavy it is and how unique to embedded
(specifically Cortex-M) systems it is. Every task, including the `init` and
idle loop have to be wrapped in the `#[app]` macro that does all of the
magic. Things that *look* like regular statics get wrapped in mutex-like
constructs that get handled differently based on priority at the start of the
tasks that declare that they use that resource.

[RTFM]: https://github.com/japaric/cortex-m-rtfm

While you can do some really cool things with RTFM, I can't help but feel
like its system of hardware/software tasks is simply an alternate route to
accomplishing the same goals as a `Future`s-driven solution, albiet in a
largely incompatible manner.

## My Ideal World

In my ideal world, IO on embedded devices ends up looking much the same as
asynchronous IO in `std`-capable contexts. A lot of work has gone into making
the `Future` trait `no_std` compatible and it would be really cool to see it
as the standard for IO *everywhere*. Unfortunately, there are still some
issues around `async`/`await` in `no_std` contexts: `thread_local!` is
currently used to get the `LocalWaker` down to the `Future` being polled
([see thread][thread]). This isn't an insurmountable problem, as Nemo157
points out, and they even have a working alternative `async`/`await`
implementation [here][embrio-async]. I would love to see a set of
`Future`s-first interfaces that define their own interrupt handlers to handle
task wakeup/notification. To run these `Future`s, we'll also need a
sufficiently robust executor, ideally one that can juggle more than one task
at a time and that doesn't simply poll everything in a tight loop.

[thread]: https://internals.rust-lang.org/t/pre-rfc-allowing-async-await-in-no-std/8460
[embrio-async]: https://github.com/Nemo157/embrio-rs/tree/master/embrio-async