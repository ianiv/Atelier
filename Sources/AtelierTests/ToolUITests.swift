@testable import Atelier
import SwiftUI
import Testing

/// The shared tool chrome (`ToolUI.swift`) and Create's canvas tools on it: the picker must keep
/// Create's segments, order and symbols exactly as they were before the move.
@Suite(.tags(.smoke))
@MainActor
struct ToolUITests {
  @Test func canvasToolKeepsSegmentsInOrder() {
    #expect(CanvasTool.allCases == [.move, .brush, .eraser, .select])
    #expect(CanvasTool.allCases.map(\.title) == ["Move", "Brush", "Eraser", "Select"])
    #expect(CanvasTool.allCases.map(\.systemImage) == ["hand.raised", "paintbrush.pointed", "eraser", "wand.and.sparkles"])
    #expect(CanvasTool.allCases.map(\.id) == CanvasTool.allCases)
  }

  @Test func pickerOffersEveryToolByDefault() {
    let picker = ToolPicker("Canvas Tool", selection: .constant(CanvasTool.move), help: "")
    #expect(picker.tools == Array(CanvasTool.allCases))
    #expect(CanvasTool.allCases.allSatisfy(picker.isEnabled))
  }

  @Test func pickerEnablesSegmentsOneByOne() {
    let picker = ToolPicker(
      "Canvas Tool", selection: .constant(CanvasTool.move), tools: [.move, .brush, .select], help: "",
      isEnabled: { $0 != .brush })
    #expect(picker.tools == [.move, .brush, .select])
    #expect(picker.isEnabled(.move))
    #expect(!picker.isEnabled(.brush))
    #expect(picker.isEnabled(.select))
  }

  @Test func brushSizesAreCreatesSizes() {
    #expect(BrushSizeMenu.sizes == [8, 16, 32, 64, 128, 256])
    let menu = BrushSizeMenu("Mask Brush Size", size: .constant(64), help: "")
    #expect(menu.sizes == BrushSizeMenu.sizes)
  }

  @Test func panelSplitsOnlyWithASecondGroup() {
    #expect(!ToolBarPanel { Text("One") }.splits)
    #expect(ToolBarPanel { Text("One") } second: { Text("Two") }.splits)
    #expect(ToolBarPanel { Text("One") } second: { Text("Two") } footer: { Text("Note") }.splits)
  }

  @Test func brushOutlineScalesWithZoom() {
    #expect(BrushOutline(center: .zero, radius: 16, pointsPerPixel: 0.5).diameter == 16)
    #expect(BrushOutline(center: nil, radius: 16, pointsPerPixel: 2).diameter == 64)
    #expect(BrushOutline(center: .zero, radius: -1, pointsPerPixel: 1).diameter == 0)
  }
}
