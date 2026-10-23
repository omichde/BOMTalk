// swift-tools-version: 6.2

import PackageDescription

let package = Package(
	name: "BOMTalk",
	platforms: [
		.iOS(.v17),
		.macOS(.v14),
	],
	products: [
		.library(name: "BOMTalk", targets: ["BOMTalk"]),
	],
	targets: [
		.target(name: "BOMTalk"),
		.testTarget(name: "BOMTalkTests", dependencies: ["BOMTalk"]),
	]
)
