//
//  FCPListSection.swift
//  flutter_carplay
//
//  Created by Oğuzhan Atalay on 21.08.2021.
//

import CarPlay

@available(iOS 14.0, *)
class FCPListSection {
  private(set) var _super: CPListSection?
  private(set) var elementId: String
  private var header: String?
  // Built on the first `get` rather than at parse time, so
  // `reuseUnchangedItems` can swap in live rows first. Building a row sets its
  // image, which CarPlay resizes synchronously on the main thread — for a
  // few hundred rows that's around a second.
  private var items: [CPListTemplateItem]?
  private var objcItems: [FCPListTemplateItem]
  private var sectionIndexEnabled: Bool

  init(obj: [String: Any]) {
    self.elementId = obj["_elementId"] as! String
    self.header = obj["header"] as? String
    // Defaults to false: a non-nil sectionIndexTitle makes CarPlay render the
    // section's first letter between the list's up/down scroll buttons, which
    // reads as clutter for media lists. Opt in per-section when a real
    // alphabetical index is wanted.
    self.sectionIndexEnabled = obj["sectionIndexEnabled"] as? Bool ?? false
    self.objcItems = (obj["items"] as! [[String: Any]]).map { dict -> FCPListTemplateItem in
      guard let runtimeType = dict["runtimeType"] as? String else {
        fatalError("FCPListSection.init: Missing runtimeType in item")
      }

      if runtimeType == "FCPListImageRowItem" {
        return FCPListImageRowItem(obj: dict) as FCPListTemplateItem
      } else if runtimeType == "FCPListItem" {
        return FCPListItem(obj: dict) as FCPListTemplateItem
      } else {
        fatalError("FCPListSection.init: Unknown item runtimeType: \(runtimeType)")
      }
    }
  }

  var get: CPListSection {
    let sectionIndexTitle = sectionIndexEnabled ? header : nil
    let items = self.items ?? objcItems.map { $0.get }
    self.items = items

    let listSection = CPListSection.init(
      items: items, header: header, sectionIndexTitle: sectionIndexTitle)

    self._super = listSection
    return listSection
  }

  public func getFCPListTemplateItems() -> [FCPListTemplateItem] {
    return objcItems
  }

  /// Replaces each not-yet-built row in [newSections] that renders
  /// identically to a live row in [oldSections] with that live row (which
  /// adopts the new row's element id), so an update only builds rows whose
  /// content actually changed. Dart re-sends whole lists for any change — a
  /// favorite toggled, covers resolved, a download finished — and rebuilding
  /// every row each time blocked the main thread long enough to stall the Now
  /// Playing screen. Each live row is handed out at most once.
  static func reuseUnchangedItems(in newSections: [FCPListSection], from oldSections: [FCPListSection]) {
    var live: [String: [FCPListItem]] = [:]
    for section in oldSections {
      for case let item as FCPListItem in section.objcItems where item._super != nil {
        live[item.contentKey, default: []].append(item)
      }
    }
    guard !live.isEmpty else { return }

    for section in newSections where section.items == nil {
      var built: [CPListTemplateItem] = []
      section.objcItems = section.objcItems.map { item in
        guard let new = item as? FCPListItem,
          let candidates = live[new.contentKey],
          let index = candidates.firstIndex(where: { $0.hasSameContent(as: new) }),
          let liveItem = candidates[index]._super
        else {
          built.append(item.get)
          return item
        }
        let old = candidates[index]
        live[new.contentKey]!.remove(at: index)
        old.adoptIdentity(of: new)
        built.append(liveItem)
        return old
      }
      section.items = built
    }
  }
}
