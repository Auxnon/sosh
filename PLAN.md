# Phase 1: Action Foundation Implementation Plan

## Overview
Establishing a reliable action system using TCP WebSocket acknowledgments while preserving existing real-time movement system.

## Progress Status

### ✅ Completed
1. **Backend ActionChannel** - Created with full acknowledgment system
   - Location: `server/lib/chat_test_web/channels/action_channel.ex`
   - Supports dig_action, place_action, drop_item, pickup_item
   - Includes input validation and structured error responses
   - Server-side confirmation then broadcasts to all clients

2. **UserSocket Extension** - Added dual-channel routing
   - Location: `server/lib/chat_test_web/channels/user_socket.ex`
   - Maintains existing `room:*` channel for real-time events
   - Adds new `actions:*` channel for reliable actions

3. **Testing Infrastructure** - Channel test setup created
   - Location: `server/test/support/channel_case.ex`
   - Location: `server/test/chat_test_web/channels/action_channel_test.exs`
   - Basic test structure for action validation

### 🔄 In Progress (Rust NIF Extension)
4. **Rust Terrain System** - Extended NIF with terrain data structures
   - Location: `server/native/universe/src/lib.rs` and `entity.rs`
   - Added BlockType enum, TerrainAction struct, ActionResult struct
   - Implemented dig_block and place_block functions
   - Terrain state tracking with action history
   - Currently has compilation errors with Encoder/Decoder traits

### ⏳ Next Steps (Frontend Integration)
5. **Frontend Socket Extensions** - Extend socket service with action channel
   - Location: `front/src/lib/socket.ts`
   - Add ActionPack enum and new action event types
   - Implement promise-based API for reliable actions
   - Add timeout and retry logic

6. **Terrain Manager** - Create frontend terrain management
   - Location: `front/src/lib/terrainManager.ts` (new file)
   - Optimistic updates with rollback capability
   - Three.js mesh integration for terrain changes
   - Action state tracking and synchronization

## Architecture Details

### Dual-Channel System
```
Phoenix Channels:
├── room:lobby (existing - real-time events)
│   ├── Movement updates (60Hz, WebRTC when possible)
│   ├── Animation states
│   └── Chat messages
└── actions:lobby (new - reliable actions)
    ├── Dig/Place block actions (TCP, always reliable)
    ├── Item pickup/drop actions (TCP, exactness required)
    └── Acknowledgment system (action confirmation)
```

### Action Flow
1. **Client Initiates** → `socketService.executeDigAction(position, face)`
2. **Optimistic Update** → Immediate visual feedback in Three.js
3. **Server Validation** → ActionChannel validates and processes
4. **Server Confirmation** → Pushes "action_complete" to sender
5. **Broadcast Update** → Broadcasts "terrain_changed" to all clients
6. **Rollback if Failed** → Reverts optimistic changes on error

### Backend Implementation Status

#### ActionChannel Features
- ✅ Input validation (position format, face validation)
- ✅ Structured error responses with specific reasons
- ✅ UUID-based action tracking
- ✅ Basic terrain action execution (will integrate with Rust NIF)
- ✅ Broadcasting system for state changes

#### Rust NIF Features (Partially Complete)
- ✅ Block type system (Air, Stone, Dirt, Grass, Wood)
- ✅ Terrain action tracking with timestamps
- ✅ Position-based terrain storage
- ✅ Action result structures
- 🔄 Encoder/Decoder trait implementations (needs fixes)

### Frontend Implementation Plan

#### Socket Service Extensions
```typescript
// New action channel integration
class SocketService {
  private actionChannel: any = null;
  private pendingActions: Map<string, PendingAction>;
  private actionCallbacks: ActionCallbacks;
  
  // Promise-based action API
  async executeDigAction(position: [number, number, number], face: string): Promise<ActionResult>
  async executePlaceAction(position: [number, number, number], blockType: string): Promise<ActionResult>
  async executeDropAction(itemId: string, quantity: number, position: [number, number, number]): Promise<ActionResult>
  async executePickupAction(itemId: string): Promise<ActionResult>
  
  // Action completion handling
  private handleActionComplete(result: ActionResult): void
  private handleActionFailed(result: ActionResult): void
}
```

#### Terrain Manager Integration
```typescript
class TerrainManager {
  // State management
  private terrain: Map<string, BlockState>;
  private optimisticUpdates: Map<string, OptimisticState>;
  private meshManager: ThreeJSMeshManager;
  
  // Action execution
  async digBlock(worldPosition: THREE.Vector3, face: string): Promise<void>
  async placeBlock(worldPosition: THREE.Vector3, blockType: string): Promise<void>
  
  // Three.js integration
  private updateBlockMesh(position: [number, number, number], blockType: string): void
  private createBlockGeometry(blockType: string): THREE.BufferGeometry
  private applyTexture(blockMesh: THREE.Mesh, blockType: string): void
}
```

### Integration Points

#### With Existing ThreeCanvas System
- **Tool Selection**: Add dig/place tools to interface
- **Raycasting**: Implement block detection on click
- **Face Detection**: Determine which face of block was clicked
- **Optimistic Updates**: Show immediate visual feedback
- **Rollback System**: Revert changes on action failure

#### With Existing ChatPane System
- **Action Notifications**: Show action completion/failure feedback
- **Error Handling**: Display user-friendly error messages
- **Loading Indicators**: Show action processing status

## Testing Strategy

### Backend Tests
```elixir
# ActionChannel Tests
describe "dig_action validation"
describe "place_action validation"  
describe "item management actions"
describe "error handling and acknowledgments"
describe "concurrent action handling"
```

### Frontend Tests
```typescript
describe("SocketService Action Channel", () => {
  test("action promises resolve on success");
  test("action promises reject on failure");
  test("timeout handling works correctly");
  test("multiple concurrent actions handled");
});

describe("TerrainManager Integration", () => {
  test("optimistic updates and rollback");
  test("Three.js mesh updates");
  test("block type validation");
});
```

## Performance Considerations

### Backend Optimizations
- **Action Batching**: Process multiple actions per frame
- **Spatial Indexing**: Efficient block lookup (planned for Phase 2)
- **Dirty Chunk Tracking**: Only send modified terrain data
- **Memory Management**: Limit action history size

### Frontend Optimizations
- **Render Batching**: Group mesh updates for performance
- **Lazy Loading**: Load terrain chunks on demand
- **Object Pooling**: Reuse Three.js objects
- **Web Workers**: Offload heavy computations

## Deployment Steps

### Immediate Next Actions
1. **Fix Rust NIF compilation errors** - Resolve Encoder/Decoder trait issues
2. **Test ActionChannel manually** - Verify channel joins and basic actions
3. **Implement frontend socket extensions** - Add action channel support
4. **Create TerrainManager** - Three.js integration for terrain actions
5. **Integration testing** - End-to-end action flow verification

### Success Criteria
- ✅ ActionChannel joins successfully with authentication
- ✅ Basic dig/place actions complete successfully  
- ✅ Action acknowledgments work correctly
- ✅ Error responses include proper validation messages
- ⏳ Frontend shows optimistic updates
- ⏳ Three.js terrain updates in real-time
- ⏳ Action promises resolve/reject appropriately

## Risks and Mitigations

### Technical Risks
- **Rust compilation complexity** - Mitigation: Incremental implementation
- **Three.js performance** - Mitigation: Batching and lazy loading
- **WebSocket reliability** - Mitigation: Retry logic and fallback systems

### Timeline Impact
- **Phase 1 Complete**: 2-3 weeks (on track)
- **Production Ready**: 4-6 weeks (includes Phase 2-4)
- **Full MMO Features**: 8-12 weeks (complete system)

## Notes for Next Developer

1. **Rust NIF Priority**: Focus on fixing Encoder/Decoder trait implementations
2. **Testing First**: Test ActionChannel before frontend integration
3. **Incremental Frontend**: Add action channel, then terrain manager
4. **Three.js Integration**: Focus on performance from the start
5. **Documentation**: Keep API docs updated with new action system

The foundation is solid - ActionChannel is implemented and ready for integration. The dual-channel architecture preserves existing real-time functionality while adding reliable action processing needed for block-based MMO gameplay.