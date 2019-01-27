+++
title = "Building an Embedded Futures Executor II"
author = "Josh Robson Chase"
date = 2019-01-27T15:00:00-05:00
draft = false
[taxonomies]
tags = ["rust", "embedded", "async", "futures"]
+++

Part 2 of my embedded executor journey!

[Part 1][ee1] ended up getting a little long, so I cut it short while still
missing some key features like more flexible task spawning and putting the
executor to sleep when there's nothing needing to be polled. This time, we'll
fill in those gaps!

[ee1]: ../embedded-executor/

<!-- more -->

## Spawning

As of my last post, our executor was capable of spawning some arbitrary
number of tasks via its `spawn` method and then `run` them all to completion.
This, unfortunately, is pretty limiting. Tasks can only be spawned before the
executor is running, and you have to wait until it's done to spawn anything
else.

What would be *really* nice is a way to spawn new tasks while the executor is
running. So what needs to happen to make this a thing? If you recall from
before, spawning a task involves 1. Adding it to the task registry and 2.
Inserting its ID into the queue to be polled. A somewhat naiive approach to
this would be to wrap the registry in an `Arc<Mutex<_>>` so that it can be
shared along with the queue. But we already have one lock - it would be nice
to not have to add another or to wrap our *entire* executor in one big lock.
So why not simply re-use the queue that we already have in place? Rather than
just a queue of task IDs, the queue will also hold new futures to spawn.

```rust
enum QueueItem<'a> {
    Poll(Index),
    Spawn(FutureObj<'a, ()>),
}

// Some aliases for convenience
type Queue<'a> = VecDeque<QueueItem<'a>>;
type QueueHandle<'a, R> = Arc<Mutex<R, Queue<'a>>>;
```

The interior loop in our `run` method will now look something like this:

```rust
while let Some(item) = self.dequeue() {
    match item {
        QueueItem::Poll(id) => { /* same thing as before */ },
        // You can always go from `FutureObj` -> `LocalFutureObj`
        QueueItem::Spawn(future) => self.spawn(future.into()),
    }
}
```

And all we need now is a nice way to package up the queue and present a nice
spawning API:

```rust
#[derive(Clone)]
struct Spawner<'a, R>(QueueHandle<'a, R>);

impl<'a, R> Spawner<'a, R> {
    fn new(handle: QueueHandle<'a, R>) -> Self {
        Spawner(handle)
    }

    fn spawn(&mut self, future: FutureObj<'a, ()>) {
        self.0.lock().push_back(QueueItem::Spawn(future));
    }
}
```

With that, we now have a cloneable, `Send`-able way to spawn new tasks!

## Sleep

The last piece of the puzzle to accomplish all of our [originally stated
goals][goals] is a way to abstract over "sleeping" the executor thread while
waiting to be notified of tasks needing to be polled.

[goals]: ../embedded-executor/#initial-goals

My (probably naiive and insufficient) approach to this was to define a simple `Sleep` trait:

```rust
trait Sleep: Default + Clone + Send + Sync + 'static {
    fn sleep(&self);

    fn wake(&self);
}
```

Which can then be threaded through our executor down to the `QueueWaker`:

```rust
struct Executor<'a, R, S: Sleep> {
    ...
    sleeper: S,
}

struct QueueWaker<'a, R, S: Sleep> {
    ...
    sleeper: S,
}
```

In the event loop:

```rust
// Before polling the task:
let waker =
    Arc::new(Mutex::new(
        QueueWaker(self.queue.clone(), id, self.sleeper.clone())
    ));

// After the "registry empty" check:
self.sleeper.sleep();
```

In the `Wake::wake` method:

```rust
arc_self.queue.lock().push_back(arc_self.id);
arc_self.sleeper.wake();
```

While this may not be sufficient for every use case, it seems to work well
enough for now. It could be implmented as an [AtomicBool] flag that's checked
in a [core::sync::atomic::spin_loop_hint][spin_loop_hint] loop, or something
fancier like a [Condvar]. On Cortex-M systems, you can use the `wfi` or `wfe`
instructions, assuming events are going to come in as interrupts or events
from other cores.

[AtomicBool]: https://doc.rust-lang.org/core/sync/atomic/struct.AtomicBool.html
[Condvar]: https://doc.rust-lang.org/std/sync/struct.Condvar.html
[spin_loop_hint]: https://doc.rust-lang.org/core/sync/atomic/fn.spin_loop_hint.html

## Wrap-up

Aaaand that's pretty much it! There's a bit more to the final (for now)
implementation to make things more ergonomic or efficient, and plenty of `R:
RawMutex + Sync + Send` bounds that I've glossed over to cut down on the
noise, but the core of my embedded executor is all there. You can find it on
[crates.io][crate] and [GitLab] if you want to dig deeper into its internals
and documentation.

[crate]: https://crates.io/crates/embedded-executor/
[GitLab]: https://gitlab.com/polymer-kb/firmware/embedded-executor/