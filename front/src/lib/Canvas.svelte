<script lang="ts">
  import { onMount } from "svelte";
  import { create } from "./instance";

  export let width = 800;
  export let height = 600;

  let element: HTMLCanvasElement;

  onMount(() => {
    element.width = width || window.innerWidth;
    element.height = height || window.innerHeight;
    create(element);
  });
</script>

<canvas bind:this={element} class="rounded-md"></canvas>
