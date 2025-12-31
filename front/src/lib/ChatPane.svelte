<script lang="ts">
    import ChatInput from "./ChatInput.svelte";
    import { onMount, onDestroy } from "svelte";
    import * as THREE from "three";
    import { player, cameraRef } from "./World";

    interface ChatMessage {
        id: string;
        text: string;
        position: THREE.Vector3;
        timestamp: number;
        isOwn: boolean;
        playerId: string;
    }

    // HashMap of player messages: playerId -> ChatMessage[]
    let playerMessages: Map<string, ChatMessage[]> = new Map();
    const MAX_MESSAGES_PER_PLAYER = 5;
    const MESSAGE_STACK_OFFSET = 60; // pixels between stacked messages
    // let scene: THREE.Scene;
    // let camera: THREE.PerspectiveCamera;
    let updateInterval: number;

    onMount(() => {
        // Update bubble positions frequently for smooth 3D tracking
        updateInterval = setInterval(() => {
            // Force reactivity to update bubble positions
            playerMessages = new Map(playerMessages);
        }, 50); // Update every 50ms for smooth movement
    });

    onDestroy(() => {
        if (updateInterval) {
            clearInterval(updateInterval);
        }
    });

    function addMessageToPlayer(playerId: string, message: ChatMessage) {
        if (!playerMessages.has(playerId)) {
            playerMessages.set(playerId, []);
        }
        
        const messages = playerMessages.get(playerId)!;
        messages.push(message);
        
        // Remove oldest messages if we exceed the limit
        if (messages.length > MAX_MESSAGES_PER_PLAYER) {
            messages.shift();
        }
        
        // Trigger reactivity
        playerMessages = new Map(playerMessages);
    }

    function handleSendMessage(text: string) {
        const ownPlayerId = "player-own";
        const newMessage: ChatMessage = {
            id: Date.now().toString(),
            text,
            position: player.position.clone().add({ x: 0, y: 2.5, z: 0 }),
            timestamp: Date.now(),
            isOwn: true,
            playerId: ownPlayerId,
        };

        addMessageToPlayer(ownPlayerId, newMessage);

        // Simulate receiving a response from another player
        setTimeout(
            () => {
                const otherPlayerId = `player-${Math.floor(Math.random() * 3) + 1}`;
                const responseMessage: ChatMessage = {
                    id: (Date.now() + 1).toString(),
                    text: `Response to: ${text}`,
                    position: new THREE.Vector3(
                        (Math.random() - 0.5) * 10,
                        2 + Math.random() * 3,
                        (Math.random() - 0.5) * 10,
                    ),
                    timestamp: Date.now() + 1,
                    isOwn: false,
                    playerId: otherPlayerId,
                };
                addMessageToPlayer(otherPlayerId, responseMessage);
            },
            1000 + Math.random() * 2000,
        );
    }

    function projectToScreen(position: THREE.Vector3): {
        x: number;
        y: number;
    } {
        const vector = position.clone();
        vector.project(cameraRef.camera);

        const x = (vector.x * 0.5 + 0.5) * window.innerWidth;
        const y = (-vector.y * 0.5 + 0.5) * window.innerHeight;

        return { x, y };
    }

    function clampToScreen(x: number, y: number, bubbleWidth: number = 250, bubbleHeight: number = 50): {
        x: number;
        y: number;
    } {
        const margin = 10;
        const clampedX = Math.max(margin + bubbleWidth / 2, Math.min(window.innerWidth - margin - bubbleWidth / 2, x));
        const clampedY = Math.max(margin + bubbleHeight / 2, Math.min(window.innerHeight - margin - bubbleHeight / 2, y));
        
        return { x: clampedX, y: clampedY };
    }

    function getStackedPosition(basePosition: THREE.Vector3, stackIndex: number): {
        x: number;
        y: number;
    } {
        const screenPos = projectToScreen(basePosition);
        const offsetY = screenPos.y - (stackIndex * MESSAGE_STACK_OFFSET);
        return clampToScreen(screenPos.x, offsetY);
    }
</script>

<div class="chat-pane">
    <!-- Floating chat bubbles grouped by player -->
    {#each Array.from(playerMessages.entries()) as [playerId, messages] (playerId)}
        {#each messages as message, index (message.id)}
            {@const stackedPos = getStackedPosition(message.position, index)}
            <div
                class="chat-bubble {message.isOwn ? 'own' : 'other'}"
                style="left: {stackedPos.x}px; top: {stackedPos.y}px;"
            >
                <div class="bubble-content">
                    {message.text}
                </div>
                <div class="bubble-tail {message.isOwn ? 'right' : 'left'}"></div>
            </div>
        {/each}
    {/each}

    <!-- Chat input -->
    <ChatInput onSendMessage={handleSendMessage} />
</div>

<style>
    .chat-pane {
        position: fixed;
        top: 0;
        left: 0;
        width: 100%;
        height: 100%;
        pointer-events: none;
        z-index: 100;
    }

    .chat-bubble {
        position: absolute;
        pointer-events: auto;
        max-width: 250px;
        transform: translate(-50%, -50%);
        animation: fadeIn 0.3s ease-out;
        filter: drop-shadow(0 2px 8px rgba(0, 0, 0, 0.15));
    }

    .bubble-content {
        padding: 12px 16px;
        border-radius: 20px;
        font-size: 14px;
        line-height: 1.4;
        word-wrap: break-word;
        position: relative;
        z-index: 1;
    }

    .chat-bubble.own .bubble-content {
        background: #0084ff;
        color: white;
        border-bottom-right-radius: 4px;
    }

    .chat-bubble.other .bubble-content {
        background: #e4e6eb;
        color: #050505;
        border-bottom-left-radius: 4px;
    }

    .bubble-tail {
        /* position: absolute; */
        /* width: 0; */
        /* height: 0; */
        /* border-style: solid; */
        /* bottom: 0; */
        position: absolute;
        bottom: 0;
        /* left: 50%; */
        width: 0;
        height: 0;
        border: 10px solid transparent;
        border-bottom: 0;
        margin-left: 0px;
        margin-bottom: -9px;
    }

    .bubble-tail.right {
        right: 2px;
        border-top-color: #0084ff;
        /* bottom: -8px; */
        /* border-width: 8px 8px 0 8px; */
        /* border-color: transparent transparent transparent #0084ff; */
    }

    .bubble-tail.left {
        border-top-color: #e4e6eb;
        left: 2px;
        /* border-width: 8px 8px 8px 0; */
        /* border-color: transparent #e4e6eb transparent transparent; */
    }

    @keyframes fadeIn {
        from {
            opacity: 0;
            transform: translate(-50%, -50%) scale(0.8);
        }
        to {
            opacity: 1;
            transform: translate(-50%, -50%) scale(1);
        }
    }

    /* Override ChatInput pointer-events */
    .chat-pane :global(.chat-input-container) {
        pointer-events: auto;
    }
</style>
