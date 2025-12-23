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
    }

    let messages: ChatMessage[] = [];
    // let scene: THREE.Scene;
    // let camera: THREE.PerspectiveCamera;
    let updateInterval: number;

    onMount(() => {
        // Get Three.js scene and camera from the global window or emit event
        // window.addEventListener('three-scene-ready', (event: Event) => {
        //     const customEvent = event as CustomEvent;
        //     scene = customEvent.detail.scene;
        //     camera = customEvent.detail.camera;
        // });

        // Update bubble positions frequently for smooth 3D tracking
        updateInterval = setInterval(() => {
            // Force reactivity to update bubble positions
            messages = [...messages];
        }, 50); // Update every 50ms for smooth movement
    });

    onDestroy(() => {
        if (updateInterval) {
            clearInterval(updateInterval);
        }
    });

    function handleSendMessage(text: string) {
        const newMessage: ChatMessage = {
            id: Date.now().toString(),
            text,
            position: player.position.clone().add({x: 0,y:2.5,z:0}),
            timestamp: Date.now(),
            isOwn: true,
        };

        messages.push(newMessage);

        // Simulate receiving a response
        setTimeout(
            () => {
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
                };
                messages = [...messages, responseMessage];
            },
            1000 + Math.random() * 2000,
        );
    }

    function projectToScreen(position: THREE.Vector3): {
        x: number;
        y: number;
    } {
        // if (!scene || !camera) {
        //     console.log("not ready", scene)
        //     return { x: 50, y: 50 }; // Default position if scene not ready
        // }

        const vector = position.clone();
        vector.project(cameraRef.camera);

        const x = (vector.x * 0.5 + 0.5) * window.innerWidth;
        const y = (-vector.y * 0.5 + 0.5) * window.innerHeight;

        return { x, y };
    }
</script>

<div class="chat-pane">
    <!-- Floating chat bubbles -->
    {#each messages as message (message.id)}
        {@const screenPos = projectToScreen(message.position)}
        <div
            class="chat-bubble {message.isOwn ? 'own' : 'other'}"
            style="left: {screenPos.x}px; top: {screenPos.y}px;"
        >
            <div class="bubble-content">
                {message.text}
            </div>
            <div class="bubble-tail {message.isOwn ? 'right' : 'left'}"></div>
        </div>
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
        border-bottom-right-radius: 6px;
    }

    .chat-bubble.other .bubble-content {
        background: #e4e6eb;
        color: #050505;
        border-bottom-left-radius: 6px;
    }

    .bubble-tail {
        position: absolute;
        width: 0;
        height: 0;
        border-style: solid;
        bottom: 0;
    }

    .bubble-tail.right {
        right: -8px;
        border-width: 8px 0 8px 8px;
        border-color: transparent transparent transparent #0084ff;
    }

    .bubble-tail.left {
        left: -8px;
        border-width: 8px 8px 8px 0;
        border-color: transparent #e4e6eb transparent transparent;
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
