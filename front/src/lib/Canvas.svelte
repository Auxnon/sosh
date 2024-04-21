<script lang="ts">
  import { onMount } from "svelte";
  //   import { getContext } from "svelte";
  //   import { writable } from "svelte/store";
  import { create } from "./instance";

  let element: HTMLCanvasElement;

  onMount(() => {
    create(element);
  });
</script>

<canvas bind:this={element}></canvas>
