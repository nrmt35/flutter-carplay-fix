import 'package:uuid/uuid.dart';

/// A button displayed on the shared [CPNowPlayingTemplate].
///
/// https://developer.apple.com/documentation/carplay/cpnowplayingbutton
/// iOS 14.0+
///
/// Custom addition: the stock plugin does not expose
/// `CPNowPlayingTemplate.nowPlayingButtons` at all, so this and its
/// subclasses (and [FlutterCarplay.updateNowPlayingButtons]) were added on
/// top of the upstream package.
abstract class CPNowPlayingButton {
  /// Unique id of the object.
  final String _elementId;

  /// The type of button as CarPlay understands it. Set by each subclass.
  final String type;

  /// Whether the button should render in its "active"/highlighted state.
  /// The app is responsible for keeping this in sync with player state and
  /// calling [FlutterCarplay.updateNowPlayingButtons] again after toggling it.
  final bool isSelected;

  /// The block invoked after the user taps the button.
  final void Function()? onPress;

  CPNowPlayingButton({
    required this.type,
    this.isSelected = false,
    this.onPress,
    String? id,
  }) : _elementId = id ?? const Uuid().v4();

  Map<String, dynamic> toJson() => {
    '_elementId': _elementId,
    'type': type,
    'isSelected': isSelected,
  };

  String get uniqueId => _elementId;
}

/// A toggle button on the shared Now Playing screen for turning shuffle on
/// or off.
/// https://developer.apple.com/documentation/carplay/cpnowplayingshufflebutton
/// iOS 14.0+
class CPNowPlayingShuffleButton extends CPNowPlayingButton {
  CPNowPlayingShuffleButton({super.isSelected, super.onPress, super.id})
    : super(type: 'shuffle');
}

/// A button on the shared Now Playing screen for cycling repeat modes.
/// https://developer.apple.com/documentation/carplay/cpnowplayingrepeatbutton
/// iOS 14.0+
///
/// CarPlay draws this button's glyph from the equivalent
/// `MPRemoteCommandCenter.changeRepeatModeCommand.currentRepeatType`, which
/// is a 3-way value (off/all/one) — a plain on/off `isSelected` can't convey
/// "repeat one" vs "repeat all", so [repeatMode] carries the exact mode
/// instead. Must be one of `'off'`, `'all'`, `'one'`.
class CPNowPlayingRepeatButton extends CPNowPlayingButton {
  final String repeatMode;

  CPNowPlayingRepeatButton({required this.repeatMode, super.onPress, super.id})
    : super(type: 'repeat', isSelected: repeatMode != 'off');

  @override
  Map<String, dynamic> toJson() => {...super.toJson(), 'repeatMode': repeatMode};
}

/// A custom image button on the shared Now Playing screen, for actions with
/// no dedicated CarPlay button class (e.g. app-specific toggles).
/// https://developer.apple.com/documentation/carplay/cpnowplayingimagebutton
/// iOS 14.0+
///
/// Custom addition: not part of the upstream package.
class CPNowPlayingImageButton extends CPNowPlayingButton {
  /// Supports the same formats as `CPListItem.image`/`CPGridButton.image`:
  /// Flutter asset path, SVG asset (rasterized before sending natively),
  /// `file://` path, or network URL.
  final String image;

  CPNowPlayingImageButton({
    required this.image,
    super.isSelected,
    super.onPress,
    super.id,
  }) : super(type: 'image');

  @override
  Map<String, dynamic> toJson() => {...super.toJson(), 'image': image};
}
