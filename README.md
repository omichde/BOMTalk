# BOMTalk

A rather unknown part of GameKit is its ad hoc networking between devices by means of Bluetooth or WiFi using Bonjour services. This immensly simplifies sharing data between iOS devices, but the API is unconvenient for most purposes and somehow aging, offering no clean delegate or block based callback mechanism. This is what BOMTalk offers:

- GameKit based with support for Bluetooth and WiFi ad hoc networks
- provides either a block-based or delegate-protocol or (multicast) notifications API
- sends and receives arbitrarily sized data (no GameKit limit)
- automatically keeps one connection slot open for up to 15 simultaneous connections per session
- hides GameKits weird delegates/class callbacks and states

# Installation

(soon)

# Documentation

(soon)

# Version

## 0.8:

- basic network debug view controller
- multiplayer pong basically working

## 0.7:

- prepared pong game for multiplayer

## 0.6:

- new sample: pong game (local mode only)

## 0.5:

- streamlined API for blocks, delegates and notifications

## 0.4:

- progress API

## 0.3:

- merged some callbacks
- refined API

## 0.2:

- expanded delegates

## 0.1:

- two samples: Pasteboard, Roll-the-Dice

# Contact

Oliver Michalak - [oliver@werk01.de](mailto:oliver@werk01.de) - [@omichde](http://twitter.com/omichde)

## Tags

iOS, GameKit, Bluetooth, WiFi, ad hoc, network, blocks, delegate, multicast

## License

BOMTalk is available under the MIT license:

	Permission is hereby granted, free of charge, to any person obtaining a copy
	of this software and associated documentation files (the "Software"), to deal
	in the Software without restriction, including without limitation the rights
	to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
	copies of the Software, and to permit persons to whom the Software is
	furnished to do so, subject to the following conditions:

	The above copyright notice and this permission notice shall be included in
	all copies or substantial portions of the Software.

	THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
	IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
	FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
	AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
	LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
	OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
	THE SOFTWARE.
