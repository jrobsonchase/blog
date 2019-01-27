+++
title = "Building an Embedded Futures Executor"
author = "Josh Robson Chase"
date = 2019-01-26T22:00:00-05:00
draft = false
[taxonomies]
tags = ["rust", "embedded", "async", "futures"]
+++

Custom keyboard development part 3!

After discovering that the `embedded-hal` ecosystem [wasn't quite what I
wanted it to be][frustrations], I set out to build the abstractions that *I*
wanted to use, namely: async-first and [core::future] compatible. The first
thing on the list? A way to run the `Future`s of course!

Side note: My project's [landing page] has got some more content these days!

[frustrations]: ../embedded-frustrations/
[core::future]: https://doc.rust-lang.org/core/future/index.html
[landing page]: https://gitlab.com/polymer-kb/polymer/blob/7b667e3f41f8d9b2013f9289aec053170b8d3cce/README.md

<!-- more -->

## Initial Goals

Some initial goals for this project:

* Support an arbitrary number of tasks
* Only poll futures that are actually ready to be polled
* Provide a "spawner" type that can allow tasks to spawn more tasks
* Provide a mechanism to put the executor to sleep if nothing needs to be
  polled.

Some non-goals:

* Support platforms without `alloc` support[^1]

[heapless]: https://docs.rs/heapless/0.4.1/heapless/

## Foundation Types

First things first: we need to understand the traits behind asynchrony in
Rust. For this project, I'm not too concerned about keeping things working on
stable - I want to keep up to date with the latest and greatest!

### Future

So let's look at the [Future] trait first:

[Future]: https://doc.rust-lang.org/core/future/trait.Future.html

```rust
trait Future {
    type Output;
    fn poll(
        self: Pin<&mut Self>,
        lw: &LocalWaker
    ) -> Poll<Self::Output>;
}
```

Let's ignore *most* of it for now and look at the [Poll] return type.

### Poll

This is what signals whatever is driving the future as to whether or not it's
done. It looks like this:

[Poll]: https://doc.rust-lang.org/core/task/enum.Poll.html

```rust
enum Poll<T> {
    Ready(T),
    Pending,
}
```

When implementing an executor, one *could* simply call the `poll` method
repeatedly until it returns its `Ready` variant. This isn't a terribly
efficient way to go about driving a future though - it wastes cycles checking
for a result that, depending on its source, may not arrive for quite some
time (at least in terms of CPU time). This is where the [LocalWaker] comes
in.

### LocalWaker

The `LocalWaker` is essentially a [trait object] for a trait that
conceptually looks something like this:

```rust
trait Wake: Clone {
    fn wake(&self);
}
```

It's a *little* more complicated than that since there's actually a
[different Wake trait][Wake] defined in `std`, and there's kind of a weird
distinction between local and non-local waking[^2], but for now, this
understanding is good enough. We'll get into it more later. withoutboats
wrote a great overview of the trait over a couple of [blog][boats1]
[posts][boats2] earlier this month that are definitely worth a read.

[LocalWaker]: https://doc.rust-lang.org/core/task/struct.LocalWaker.html
[trait object]: https://doc.rust-lang.org/book/ch17-02-trait-objects.html
[Wake]: https://doc.rust-lang.org/std/task/trait.Wake.html
[boats1]: https://boats.gitlab.io/blog/post/wakers-i/
[boats2]: https://boats.gitlab.io/blog/post/wakers-ii/

Anyway, the idea is that the `Future` being polled should, if it's not ready,
somehow arrange for `wake` to be called once it's ready to be polled again.
How exactly it makes this happen is left up to the future implementation, and
is not really our problem (for right now). What *is* our problem is what
`wake` should actually do. In most cases, it needs to do two things:

1. Wake up the executor if its thread is asleep or in some sort of low-power
    state
2. Tell the executor that this task in particular is ready to be polled

Since our goal is to implement our own executor, we'll need to provide a
suitable "Wake" implementation to get things a-polling.

### Pin<&mut what?>

Last but certainly not least, you'll probably notice is the `self` argument
that has a type that's not just the implicit `Self`, `&Self`, or `&mut Self`.
This is an instance of the [arbitrary self types] feature, which allows you
to define methods on more types than the usual `self` variants, e.g.
`Arc<Self>`, `Box<Self>`, etc. In *this specific* case, it gives the `poll`
method a static guarantee that its receiver won't ever be moved in memory.
Why does this matter? It allows for borrows that live across points where
asynchronous code could be suspended and return a `Poll::Pending`. Again,
withoutboats has a great series of blog posts about this problem and how its
solution came to be. The rabbit hole starts [here][boats3].

[arbitrary self types]: https://github.com/rust-lang/rust/issues/44874
[boats3]: https://boats.gitlab.io/blog/post/2018-01-25-async-i-self-referential-structs/

The ins and outs of the `Pin` type aren't *that* important for our executor,
but it's still good to have a general idea as to what it's all about.

## Laying The Groundwork

At its core, our executor needs two things:

1. A way to figure out what needs to be polled
2. A way to keep track of the tasks currently in existence

For 1, we could simply keep a boolean flag along side each task and ask each
"do you need to be polled?" This approach isn't much better than just polling
everything though, so we'll try to come up with something better. Another
option is to have a queue of "things to poll." This fits well with our second
requirement, assuming it supports fast lookup via some sort of key. A
[BTreeMap] could work, but we don't really need to ascribe any meaning to the
keys, and we might not want the insert/lookup overhead. A [Vec] could also
work, but then there's the issue of indexes getting re-used, which might
result in things getting polled when they shouldn't. [generational_arena] to
the rescue! The [Arena] container provides fast lookup (it's an array) and
pretty good guarantees that no two elements will get the same `Index`, even
in the event that the same slot is technically re-used. So we can use this to
store all of our tasks, which are represented as [Future trait
objects][LocalFutureObj].

[Vec]: https://doc.rust-lang.org/alloc/vec/struct.Vec.html
[BTreeMap]: https://doc.rust-lang.org/alloc/collections/btree_map/struct.BTreeMap.html

So where does that leave us as far as the queue is concerned? It's hard to go
wrong with the [VecDeque] from the standard library, so let's give that a shot!

So our basic executor looks something like this:

```rust
// Note: the lifetime allows us to drive futures that aren't
// owned by the executor. Don't worry too much about it for now.
struct Executor<'e> {
    registry: Arena<LocalFutureObj<'e, ()>>,
    queue: VecDeque<Index>,
}
```

and its event loop looks a bit like this:

```rust
fn run(&mut self) {
    loop {
        while let Some(id) = self.queue.pop_front() {
            if let Some(future) = self.registry.get_mut(id) {
                // so that we have a Pin<&mut _> to call `poll` on
                let pinned = Pin::new(future);

                let waker = unimplemented!();

                match pinned.poll(&waker) {
                    Poll::Ready(_) => {
                        self.registry.remove(id);
                    }
                    Poll::Pending => {}
                }
            }
        }
        if self.registry.is_empty() {
            break;
        }
    }
}
```

### Waking

If you were reading closely, you'll notice that the `waker` is just a
placeholder. So how do we get one? We've already got a queue containing task
IDs to poll, so why not define our waker as "the thing that enqueues the ID?"
For this, we need a way to refer to share the queue, so we'll wrap it in
an [Arc] and [lock_api]'s [Mutex] type, which lets us be generic over the
*actual* mutex implementation.[^3] With that, our executor looks like this:

```rust
struct Executor<'e, R> {
    registry: Arena<LocalFutureObj<'e, ()>>,
    queue: Arc<Mutex<R, VecDeque<Index>>>,
}
```

and our fancy new waker looks like this:

```rust
struct QueueWaker<R> {
    queue: Arc<Mutex<R, VecDeque<Index>>>,
    id: Index,
}

// Note: this is the *actual* `Wake` trait from `std`/`alloc`
// https://doc.rust-lang.org/alloc/task/trait.Wake.html
impl<R> Wake for QueueWaker<R> {
    fn wake(arc_self: &Arc<Self>) {
        arc_self.queue.lock().push_back(arc_self.id);
    }
}
```

Now, we can fill in the missing piece of the event loop:
```rust
let waker = LocalWaker::new(Arc::new(
        QueueWaker(self.queue.clone(), id)
    ));
```

Note: the queue also needs a lock, but we can't do it in the `while let` due
to [this issue][deadlock]. The workaround isn't terribly interesting - the
lock/dequeue operation just needs its own method.

[deadlock]: https://github.com/rust-lang/rust/issues/37612

With all of this defined, our executor should actually be able to drive its
futures. Spawning them is straightforward: the future gets inserted into the
Arena and its ID gets put into the queue to get polled.

```rust
fn spawn(&mut self, future: LocalFutureObj<'a, ()>) {
    let id = self.registry.insert(future);
    self.queue.lock().push_back(id);
}
```

[Arc]: https://doc.rust-lang.org/alloc/sync/struct.Arc.html
[lock_api]: https://docs.rs/lock_api/0.1.5/lock_api/
[Mutex]: https://docs.rs/lock_api/0.1.5/lock_api/struct.Mutex.html

[generational_arena]: https://docs.rs/generational-arena/0.2.1/generational_arena/
[Arena]: https://docs.rs/generational-arena/0.2.1/generational_arena/struct.Arena.html
[LocalFutureObj]: https://docs.rs/futures-preview/0.3.0-alpha.12/futures/future/struct.LocalFutureObj.html
[VecDeque]: https://doc.rust-lang.org/alloc/collections/vec_deque/struct.VecDeque.html

## Next Steps

There's still some more functionality to add - we need a spawner that can be
used from within a `Future` and a way to put the executor to sleep when
there's nothing that needs to be polled. Unfortunately, it's time to sleep! So I'll hit "pause" for now and pick back up tomorrow in [part 3.2]. Until then! 😊

[part 3.2]: ../embedded-executor-2/

## Footnotes

[^1]: This is a rather difficult problem. On one hand, it's fairly easy to
simply use [heapless] and co. to keep track of multiple futures up to some
static limit. On the other hand, the `Waker`/`LocalWaker` APIs require *some*
way of producing trait objects with a `'static` lifetime, which turns out to
be pretty challenging. I'll probably take another look into it at some later
point, but for now, `alloc` is fine.

[^2]: This actually might be changing before too long according to boats'
[second post][boats2].

[^3]: We could use a lock-free queue rather than an `Arc<Mutex<_>>`, but on
embedded systems, it might not get us a whole lot since a "mutex" is usually
just disabling/re-enabling interrupts.