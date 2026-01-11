//
//  YAWATheme.swift
//  YAWA
//
//  Created by Keith Sharman on 1/10/26.
//


import SwiftUI

enum YAWATheme {
    // Flat sky background (always)
    static let sky = Color(red: 0.07, green: 0.16, blue: 0.32)

    // Tile / card surface
 //   static let card = Color(red: 0.16, green: 0.28, blue: 0.48)

    // Slightly different surface (alerts, sections, etc.)
    static let card2 = Color(red: 0.19, green: 0.33, blue: 0.54)

    // Text tones (optional helpers)
    static let textPrimary = Color.white
    static let textSecondary = Color.white.opacity(0.75)
    static let textTertiary = Color.white.opacity(0.55)
    
    static let divider = Color.white.opacity(0.22)
    
    static let card = Color.white.opacity(0.10)         // same family as tiles
    static let cardStroke = Color.white.opacity(0.16)   // subtle border for definition
    
    static let alertIcon = Color.orange
    
    static let alertHeader = Color.yellow.opacity(0.95)
    
    static let alert = Color.yellow.opacity(0.95)
}
