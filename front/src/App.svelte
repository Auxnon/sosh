<script lang="ts">
    import ThreeCanvas from "./lib/ThreeCanvas.svelte";
    import ChatPane from "./lib/ChatPane.svelte";
</script>

<div class="app">
    <ThreeCanvas />
    <ChatPane />
</div>

<style>
    .app {
        width: 100vw;
        height: 100vh;
        margin: 0;
        padding: 0;
        overflow: hidden;
    }
</style>
