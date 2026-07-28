//
//  FCPNowPlayingButton.swift
//  flutter_carplay
//
//  Custom addition: wraps CPNowPlayingShuffleButton/CPNowPlayingRepeatButton/
//  CPNowPlayingImageButton so Dart can populate
//  CPNowPlayingTemplate.shared.nowPlayingButtons, which the stock plugin does
//  not expose.
//
//  CPNowPlayingShuffleButton/CPNowPlayingRepeatButton exist to replace
//  target-action handling of MPRemoteCommandCenter's changeShuffleModeCommand/
//  changeRepeatModeCommand, and CarPlay draws their glyph from that same
//  command center state (`currentShuffleType`/`currentRepeatType`) rather than
//  from `isSelected` alone, so both must be kept in sync here.
//

import CarPlay
import Flutter
import MediaPlayer

@available(iOS 14.0, *)
final class FCPNowPlayingButton {
  private(set) var elementId: String
  private var type: String
  private var isSelected: Bool
  private var repeatMode: String?
  private var image: String?
  private var imageData: FlutterStandardTypedData?
  private(set) var _super: CPNowPlayingButton?

  init(obj: [String: Any]) {
    self.elementId = obj["_elementId"] as! String
    self.type = obj["type"] as? String ?? "shuffle"
    self.isSelected = obj["isSelected"] as? Bool ?? false
    self.repeatMode = obj["repeatMode"] as? String
    self.image = obj["image"] as? String
    self.imageData = obj["imageData"] as? FlutterStandardTypedData
  }

  /// A stable description of this button's *visual* state, excluding the
  /// per-rebuild [elementId]. Used to skip redundant
  /// `CPNowPlayingTemplate.updateNowPlayingButtons` calls (which would redraw
  /// — and visibly flicker — every button even when nothing changed). The Dart
  /// side already dedupes, but state churn during looping playback (repeat-one)
  /// can still slip identical payloads through; this is the backstop.
  var signature: String {
    return [type, String(isSelected), repeatMode ?? "", image ?? ""].joined(separator: "|")
  }

  private func handler(button: CPNowPlayingButton) {
    DispatchQueue.main.async {
      FCPStreamHandlerPlugin.sendEvent(
        type: FCPChannelTypes.onNowPlayingButtonPressed,
        data: ["elementId": self.elementId]
      )
    }
  }

  var get: CPNowPlayingButton {
    let button: CPNowPlayingButton
    let commandCenter = MPRemoteCommandCenter.shared()

    switch type {
    case "repeat":
      button = CPNowPlayingRepeatButton(handler: self.handler)
      switch repeatMode {
      case "one":
        commandCenter.changeRepeatModeCommand.currentRepeatType = .one
      case "all":
        commandCenter.changeRepeatModeCommand.currentRepeatType = .all
      default:
        commandCenter.changeRepeatModeCommand.currentRepeatType = .off
      }
    case "shuffle":
      button = CPNowPlayingShuffleButton(handler: self.handler)
      commandCenter.changeShuffleModeCommand.currentShuffleType =
        isSelected ? .items : .off
    default:
      // "image": a plain custom toggle with no dedicated CarPlay button
      // class (e.g. the app's echo effect). The image is resolved
      // synchronously here — [imageData] is already the rasterized PNG
      // bytes for Flutter asset SVGs (resolved on the Dart side before the
      // method channel call), since CPNowPlayingImageButton, unlike
      // CPListItem, has no setter to swap the image in asynchronously later.
      let uiImage =
        makeUIImage(fromBytes: imageData)
        ?? makeUIImage(from: (image ?? "").toImageSource())
      button = CPNowPlayingImageButton(image: uiImage, handler: self.handler)
    }

    button.isSelected = isSelected
    self._super = button
    return button
  }
}
