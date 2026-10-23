//
//  Log.swift
//  BOMTalk
//

import os

extension Logger {
	static func bomtalk(_ category: String) -> Logger {
		Logger(subsystem: "de.werk01.BOMTalk", category: category)
	}
}
