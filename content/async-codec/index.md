+++
title = "Yet Another Codec Crate"
author = "Josh Robson Chase"
date = 2019-07-07T15:00:00-05:00
draft = true
[taxonomies]
tags = ["rust", "async", "futures", "codec"]
+++

Keyboard-related yak shaving!

Because you can never have too many codec crates.

<!-- more -->

## Motivation

Lately, I've had to deal with the [tokio-codec] crate for our message framing
needs at `$dayjob`. It gets the job done well, and I like its overall API,
but there are a few things about it that bug me. My first issue is that, at
the time at least, its `Framed` type only produced a `futures-0.1` `Stream +
Sink`. Since we're an async/await shop, this meant using the
`futures::compat` wrappers liberally, which just felt kind of dirty. There
*is* a [futures-codec] crate that provides the same `Encoder`/`Decoder` API,
but with a stable `Future`s `Framed` type, but it seems likely to be
superseded once [tokio-codec] updates to the new `Future` APIs. My second
issue is that it only works in applications that have `std` available due to
how heavily it leans on the [bytes] crate and the types from `std::io`, and I
want something that I can use in, say, a keyboard firmware.

[tokio-codec]: https://crates.io/crates/tokio-codec
[futures-codec]: https://crates.io/crates/futures-codec
[bytes]: https://crates.io/crates/bytes

### High-level API Goals

The two biggest goals of the design were to make it allocation and
IO-agnostic. `tokio-codec` uses the `BytesMut` type in its public API and
also requires that all errors returned by `Encoder`s and `Decoder`s be
constructed from a `std::io::Error`.

#### Issues With Error Conversion

The error conversion is done so that its
[Framed][tokio-framed] type can return a single error type. While convenient,
this seems to me to be an improper mixing of concerns. The `Codec` should
only care about serializing and deserializing the data, not errors in the
underlying stream. The majority of serialization crates crates do not
implement this conversion since they perform all of their operations on
buffers of bytes, not IO objects, so in order to satisfy the
`From<io::Error>` requirement, an enum to hold either the IO error or codec
error needs to be defined *just* for the `Codec` implementation. Furthermore,
the [encode][tokio-encode] and [decode][tokio-decode] methods only provide
byte buffers for the `Codec` to work with, so there will never even be an
opportunity for the IO variant of the error enum to be constructed in the
actual `encode`/`decode` implementations. The new API will avoid any mention
of IO errors in the `Encode` and `Decode` types and will instead leave IO
error reporting to the things that are actually dealing with IO.

[tokio-framed]: https://docs.rs/tokio-codec/0.1.1/tokio_codec/struct.Framed.html
[tokio-encode]: https://docs.rs/tokio-codec/0.1.1/tokio_codec/trait.Encoder.html#tymethod.encode
[tokio-decode]: https://docs.rs/tokio-codec/0.1.1/tokio_codec/trait.Decoder.html#tymethod.decode

#### On `BytesMut` And Its Many Uses

[tokio-codec] packs a *lot* of meaning into its use of the
[bytes::BytesMut][bytesmut] container. In `encode`, it's a growable, mutable
buffer to put bytes into. In `decode`, it's a buffer to take bytes out of
once they can be decoded into a full `Item`. In either case, you get the full
breadth of the rather large API surface of `BytesMut` to work with, and it
can take some careful reading of both its API docs and those for the `encode`
and `decode` methods to make sure you're using it correctly. The new API will
avoid the use of types that have such varied and powerful APIs and will
instead opt for more familiar structures.

[bytesmut]: https://docs.rs/bytes/0.4.12/bytes/struct.BytesMut.html

## The [async-codec] crate

[async-codec]: https://crates.io/crates/async-codec/0.4.0-alpha.1

#### What's In a Name?

First off, I wanted a descriptive, discoverable name. I found that there was
already an [async-codec][async-codec-orig] crate in existence, but it hadn't
seen any updates in over a year. I got in touch with its author, and they
were kind enough to let me take it over :)

[async-codec-orig]: https://crates.io/crates/async-codec

#### The `Decode` API

The decoder needs just one thing from its caller: some bytes to try to decode.

It has two things that it needs to communicate:

1. The number of bytes that it consumed
2. The result of consuming those bytes

The result of consuming bytes can be one of:

1. A frame was successfully decoded
2. An error was encountered while decoding the frame
3. There aren't enough bytes available to decode

In `tokio-codec`, this information is spread across the `BytesMut` argument,
through which the `Decoder` signals the number of bytes consumed, and the
`Result<Option<Item>, Error>` return type. Instead, we're going to use a simple `&[u8]` as the argument to our `decode` method, and return a tuple containing the number of bytes consumed and the result:

```rust
pub enum DecodeResult<T, E> {
    /// Item decoded successfully.
    Ok(T),
    /// A full frame was found, but an error was encountered when decoding it.
    Err(E),
    /// Not enough data to decode a full frame yet, more needs to be read.
    UnexpectedEnd,
}

/// Trait for values that can be decoded from a byte buffer
pub trait Decode {
    /// The item being decoded
    type Item;
    /// The error that may arise from a decode operation
    type Error;

    /// Attempt to decode a value from the buffer
    fn decode(&mut self, buffer: &[u8]) -> (usize, DecodeResult<Self::Item, Self::Error>);
}
```

The `Decode` implementor is free to either consume bytes as it goes and buffer them internally, or to 