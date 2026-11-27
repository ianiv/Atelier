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

  /// Create's brush is sized in frame pixels: its cursor is the size times the canvas's points per
  /// frame pixel, whatever the zoom.
  @Test func frameBrushCursorIsItsOnScreenSize() {
    #expect(BrushOutline(center: .zero, frameBrushSize: 64, pointsPerFramePixel: 0.5).diameter == 32)
    #expect(BrushOutline(center: .zero, frameBrushSize: 8, pointsPerFramePixel: 2).diameter == 16)
    #expect(BrushOutline(center: nil, frameBrushSize: 0, pointsPerFramePixel: 1).diameter == 0)
    #expect(BrushOutline(center: .zero, frameBrushSize: 16, pointsPerFramePixel: 1, erases: true).erases)
  }

  /// Below 6 points across, a cross stands in for the ring, so the cursor never vanishes.
  @Test func tinyBrushFallsBackToACross() {
    #expect(BrushOutline.minimumDiameter == 6)
    #expect(BrushOutline(center: .zero, frameBrushSize: 8, pointsPerFramePixel: 0.5).isTiny)
    #expect(BrushOutline(center: .zero, frameBrushSize: 5.9, pointsPerFramePixel: 1).isTiny)
    #expect(!BrushOutline(center: .zero, frameBrushSize: 6, pointsPerFramePixel: 1).isTiny)
    #expect(!BrushOutline(center: .zero, radius: 16, pointsPerPixel: 1).isTiny)
  }

  /// Heal's inner ring sits where its feather begins, `radius × (1 − feather)`; none for a hard
  /// brush, a tiny one, or one whose inner ring would crowd the outline.
  @Test func innerRingMarksTheFeather() {
    #expect(BrushOutline.innerRadius(radius: 40, feather: 0.25) == 30)
    #expect(BrushOutline.innerRadius(radius: 40, feather: 0) == 40)
    #expect(BrushOutline.innerRadius(radius: 40, feather: 2) == 0)
    #expect(BrushOutline.innerRadius(radius: 40, feather: -1) == 40)
    let heal = BrushOutline(center: .zero, radius: 40, pointsPerPixel: 0.5, innerRadius: 30)
    #expect(heal.diameter == 40)
    #expect(heal.innerDiameter == 30)
    #expect(BrushOutline(center: .zero, radius: 40, pointsPerPixel: 1).innerDiameter == nil)
    #expect(BrushOutline(center: .zero, radius: 2, pointsPerPixel: 1, innerRadius: 1.5).innerDiameter == nil)
    #expect(BrushOutline(center: .zero, radius: 40, pointsPerPixel: 1, innerRadius: 40).innerDiameter == nil)
  }
}
