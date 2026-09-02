#!/usr/bin/env bash
set -euo pipefail

# The first-run and replayed intro must present the abstract NF mark, rather
# than the former flag-and-dot icon extraction. Keep the SceneKit composition
# as a single glass mark so the existing turn and notch-flight animate every
# letter together.
source_file='NotchFlow/Sources/IntroAnimation.swift'

rg -F 'spin.addChildNode(Self.nfMarkNode())' "$source_file" >/dev/null
rg -F 'private static func nfMarkNode() -> SCNNode' "$source_file" >/dev/null
rg -F 'private static func nPath() -> NSBezierPath' "$source_file" >/dev/null
rg -F 'private static func fPath() -> NSBezierPath' "$source_file" >/dev/null

! rg -F 'Self.flagPath()' "$source_file"
! rg -F 'Self.dotNode()' "$source_file"
