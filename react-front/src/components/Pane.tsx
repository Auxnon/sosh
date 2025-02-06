import Bubble from "./Bubble";
import { useRef, useState, useEffect  } from "react";
import "./Pane.scss";

function scrollEvent(event: Event):void {
    const e: HTMLDivElement=event.target as HTMLDivElement
    const p= e.scrollTop/(e.scrollHeight - e.clientHeight)
    console.log(p)
}

export default function Pane({ width = 400, height = 400 }) {
  const scrollRef  = useRef<HTMLDivElement>(null);
  const [chat, setChat] = useState(Array.from({ length: 5 }));
  
  useEffect(() => {
      const current=scrollRef.current
      console.log("yes we have ", current);
      current?.addEventListener("scroll", scrollEvent)
    return ()=> current?.removeEventListener("scroll",scrollEvent)
  }, []);

  return (
    <div className="rounded-md" style={{ width, height }}>
      <div
        ref={scrollRef}
        className="rounded-md scroller m-2 overflow-scroll"
        style={{ height }}
      >
        {chat.map(() => (
          <Bubble></Bubble>
        ))}
      </div>
    </div>
  );
}
