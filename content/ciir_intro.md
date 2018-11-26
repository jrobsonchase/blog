+++
title = "Crafting Interpreters ... In Rust!"
author = "Josh Robson Chase"
date = 2018-10-23
draft = false
[taxonomies]
tags = ["rust","parsers","interpreters"]
+++

As you may or may not know, Bob Nystrom (not the [hockey
player](https://en.wikipedia.org/wiki/Bob_Nystrom)) is in the process of
writing an excellent introduction to programming language design and
implementation in the form of the book [Crafting
Interpreters](http://craftinginterpreters.com/). If you haven't already, I
would highly recommend checking it out! It walks the reader through the
design and implementation of a toy object-oriented language, `lox`. It does
this not once, but twice! The first implementation is a tree-walk interpreter
in Java and the second (not yet complete) implementation will be a bytecode
compiler/interpreter in C.

<!-- more -->

I've been meaning to go through the book for some time now, and, being the
Rust fanboy that I am, it naturally follows that I'll be going against the
grain and attempting to apply the Java instructions to Rust code. I'm going
to follow along as closely as possible to the overall structure of the
interpreter, but I expect that I'll have to make a number of small changes to
account for language differences. Overall, it should be a fun exercise!

I'll be breaking my adventure over a number of posts which will loosely
follow the structure of the book. 

To Be Continued!