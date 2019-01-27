+++
title = "Building an Embedded Futures Executor"
author = "Josh Robson Chase"
date = 2019-01-26T22:00:00-05:00
draft = true
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

## First Steps


