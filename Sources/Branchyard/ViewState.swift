import SwiftUI

/// The newest SwiftUI SDK makes `@State` a macro whose plugin ships only with full Xcode.
/// This alias points at the classic `State` property wrapper, so the app builds with
/// just the Command Line Tools as well.
typealias ViewState<Value> = SwiftUI.State<Value>
