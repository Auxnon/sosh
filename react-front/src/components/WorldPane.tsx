import { useRef, useEffect, useState } from "react";
import { click, create, moveCursor } from "../world/instance";

export default function WorldPane() {
  const containerRef: React.MutableRefObject<HTMLDivElement | null> =
    useRef(null);
  const [m, mSet] = useState({ x: 0, y: 0 });

  useEffect(() => {
    const renderer = create(800, 800);

    if (containerRef === null) {
      throw "error no reference";
    }


    function pointerMove(event: PointerEvent):boolean {
      const rect = containerRef?.current?.getBoundingClientRect();
      if (rect) {
        const x = event.clientX - rect.left;
        const y = event.clientY - rect.top;
        const xf = x / rect.width;
        const yf = y / rect.height;
        mSet({ x: xf, y: yf });

        // event.
        moveCursor(xf, yf);
        return true
      }
      return false
    }

    function pointerDown(event: PointerEvent){
        if(pointerMove(event)){
            click()
        }
    }

    // Append the renderer to the DOM
    containerRef?.current?.appendChild(renderer.domElement);
    containerRef?.current?.addEventListener("pointermove", pointerMove);
    containerRef?.current?.addEventListener("pointerdown", pointerDown);

    // Clean up on unmount
    return () => {
      // @ts-expect-error because
      containerRef.current.removeChild(renderer.domElement);
    };
  }, []);

  return (
    <>
      {" "}
      <div>
        x: {m.x} y:{m.y}
      </div>
      <div ref={containerRef} className="bg-green-500 rounded-md overflow-hidden" />
    </>
  );

  // return <div hi</div>
}
