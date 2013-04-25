# BOMTalk

Although GameKit greatly simplifies Bluetooth and WLan usage with Bonjour serviices in the background, teh API is still unconvenient for most purposes and aging, offering no clean delegate or block based callback mechanism. This is what BOMTalk offers:

- GameKit based with support for Bluetooth and WLan adhoc networks
- sends and receives arbitrarily sized data (GK limits 50K) conforming to NSCoding
- automatically keeps one connection slot open for up to 15 simultaneous connections per session
- simplifies GameKits weird delegates/class callbacks and states
- block-based or delegate-protocol or multicast notifications

# Installation

(soon)

# Documentation

(soon)

# Version

## 0.1:

- two samples: Pasteboard, Roll-the-Dice

# Contact

Oliver Michalak - [oliver@werk01.de](mailto:oliver@werk01.de) - [@omichde](http://twitter.com/omichde)

## Tags

iOS, GameKit, Bluetooth, WLan, adhoc, network, blocks, delegate, multicast

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
