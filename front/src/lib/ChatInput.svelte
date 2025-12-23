<script lang="ts">
    export let onSendMessage: (message: string) => void;
    let inputValue = '';
    let isVisible = true;

    function handleSubmit() {
        if (inputValue.trim()) {
            onSendMessage(inputValue.trim());
            inputValue = '';
        }
    }

    function handleKeydown(event: KeyboardEvent) {
        if (event.key === 'Enter' && !event.shiftKey) {
            event.preventDefault();
            handleSubmit();
        }
    }

    function toggleVisibility() {
        isVisible = !isVisible;
    }
</script>

<div class="chat-input-container" class:hidden={!isVisible}>
    <div class="chat-input-wrapper">
        <button 
            class="toggle-btn" 
            on:click={toggleVisibility}
            title="Toggle chat input"
        >
            {isVisible ? '−' : '+'}
        </button>
        
        <div class="input-group">
            <input
                type="text"
                bind:value={inputValue}
                on:keydown={handleKeydown}
                placeholder="Type a message..."
                class="chat-input"
            />
            <button 
                on:click={handleSubmit}
                class="send-btn"
                disabled={!inputValue.trim()}
            >
                Send
            </button>
        </div>
    </div>
</div>

<style>
    .chat-input-container {
        position: fixed;
        bottom: 20px;
        left: 50%;
        transform: translateX(-50%);
        z-index: 1000;
        transition: all 0.3s ease;
    }

    .chat-input-wrapper {
        background: rgba(255, 255, 255, 0.5);
        backdrop-filter: blur(10px);
        border-radius: 25px;
        padding: 12px 20px;
        box-shadow: 0 4px 20px rgba(0, 0, 0, 0.15);
        border: 1px solid rgba(0, 0, 0, 0.1);
        display: flex;
        align-items: center;
        gap: 10px;
        min-width: 300px;
        max-width: 500px;
    }

    .toggle-btn {
        width: 24px;
        height: 24px;
        border-radius: 50%;
        border: none;
        background: #e0e0e0;
        cursor: pointer;
        display: flex;
        align-items: center;
        justify-content: center;
        font-weight: bold;
        font-size: 14px;
        transition: background 0.2s;
    }

    .toggle-btn:hover {
        background: #d0d0d0;
    }

    .input-group {
        display: flex;
        flex: 1;
        gap: 8px;
        align-items: center;
    }

    .chat-input {
        flex: 1;
        padding: 10px 15px;
        border: 1px solid #e0e0e0;
        border-radius: 20px;
        outline: none;
        font-size: 14px;
        background: white;
        color: black;
        transition: border-color 0.2s;
    }

    .chat-input:focus {
        border-color: #0084ff;
    }

    .send-btn {
        padding: 8px 16px;
        background: #0084ff;
        color: white;
        border: none;
        border-radius: 18px;
        cursor: pointer;
        font-size: 13px;
        font-weight: 600;
        transition: background 0.2s;
    }

    .send-btn:hover:not(:disabled) {
        background: #0066cc;
    }

    .send-btn:disabled {
        background: #cccccc;
        cursor: not-allowed;
    }

    .hidden {
        opacity: 0;
        transform: translateX(-50%) translateY(100px);
        pointer-events: none;
    }
</style>
