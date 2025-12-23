import { Channel, Socket } from "phoenix";
import { Message, MessageCategory } from "../utils/types";
import * as inst from "./instance";
import { Vector3 } from "three";
import { Pack } from "./protocol";
import { errorOut } from "./error";

const socket = new Socket("/socket", {});
socket.connect();

let channel: Channel | undefined = undefined;

const r = (a?: number) =>
  a != null ? (2 * Math.random() - 1) * a : Math.random();

export function join(chat: Message[], setChat: React.Dispatch<Message[]>) {
  if (channel) return;

  channel = socket.channel("room:lobby", {
    greet: "" + Math.random(),
    vec: [r(5), r(5), 0],
  });

  function m(user: string, value: string, category: MessageCategory): void {
    setChat([...chat, { user, value, category }]);
  }

  const system = (s: string) => m("", s, MessageCategory.System);

  const userChat = (user: string, s: string) =>
    m(user, s, MessageCategory.User);

  const dataChat = (n: number[]) =>
    m(
      "",
      n.map((v) => Math.floor(v * 100) / 100).join(","),
      MessageCategory.Data,
    );

  setTimeout(() => {
    if (channel) {
      channel
        .join(500)
        .receive("ok", (resp) => {
          console.log("Joined successfully", resp);
          // dataChat(resp.connection_id);
          inst.setPlayer(resp.user_id);
          system("joined");
        })
        .receive("error", (resp) => {
          console.log("Unable to join", resp);
          system("failed to join");
        });

      channel.on(Pack.NEW_MESSAGE, (payload) => {
        // const messageItem = document.createElement("li");
        // messageItem.innerText = payload.body;
        // messageRef.current?.appendChild(messageItem);
        userChat(payload.user_id, payload.body);
      });

      channel.on("refresh", (payload) => {
        const numbers = payload.numbers;
        console.log("Received new numbers:", numbers);
        inst.updateEntity("", numbers);
        dataChat(numbers);
      });

      channel.on(Pack.JOINED, (o) => {
          debugger
        if(!o.user_id) errorOut('no user id')
        inst.joinEntity(o.user_id, o.vec);
      });

      channel.on(Pack.MOVE, (payload) =>
        inst.updateEntity(payload.user_id, payload.vec),
      );
    }
  }, 1000);
   }

export function sendChat(str: string) {
  channel?.push(Pack.NEW_MESSAGE, { body: str });
}

export function testChat() {
  channel?.push("get_update", {});
}

export function move(vec: Vector3) {
  channel?.push(Pack.MOVE, { vec: vec.toArray() });
}
