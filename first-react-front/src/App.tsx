import { useState, useRef, useEffect } from "react";
import reactLogo from "./assets/react.svg";
import viteLogo from "/vite.svg";
import "./App.css";

import { Socket } from "phoenix";

const socket = new Socket("/socket", {});
socket.connect();

function App() {
  const [count, setCount] = useState(0);
  const inputRef = useRef<HTMLInputElement>(null);
  const messageRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    const channel = socket.channel("room:lobby", {});

    channel
      .join()
      .receive("ok", (resp) => {
        console.log("Joined successfully", resp);
      })
      .receive("error", (resp) => {
        console.log("Unable to join", resp);
      });


    channel.on("new_msg", (payload) => {
      const messageItem = document.createElement("li");
      messageItem.innerText = payload.body;
      messageRef.current?.appendChild(messageItem);
    });

    inputRef.current?.addEventListener("keypress", (event: KeyboardEvent) => {
      if (event.key === "Enter") {
        channel.push("new_msg", { body: inputRef.current?.value ?? "NA" });
        if (inputRef.current) inputRef.current.value = "";
      }
    });
  });

  return (
    <>
      <div>
        <a href="https://vite.dev" target="_blank">
          <img src={viteLogo} className="logo" alt="Vite logo" />
        </a>
        <a href="https://react.dev" target="_blank">
          <img src={reactLogo} className="logo react" alt="React logo" />
        </a>
      </div>
      <h1>Vite + React</h1>
      <div className="card">
        <button onClick={() => setCount((count) => count + 1)}>
          count is {count}
        </button>

        <input type="text" ref={inputRef} />
        <div className="messager" ref={messageRef}>
          test
        </div>
        <p>
          Edit <code>src/App.tsx</code> and save to test HMR
        </p>
      </div>
      <p className="read-the-docs">
        Click on the Vite and React logos to learn more
      </p>
    </>
  );
}

export default App;
