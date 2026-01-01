import { Socket } from "phoenix";

interface PlayerState {
    position: [number, number, number];
    animation: number;
    face: number;
}

interface SocketMessage {
    user_id: string;
    body?: string;
    vec?: [number, number, number];
    animation?: number;
    face?: number;
}

export enum Pack {
    MOVE = 'move',
    NEW_MESSAGE = 'new_msg',
    JOINED = 'joined',
    LOOK = 'look',
    ANIMATION = 'animation',
    EXPRESSION = 'face',
}

class SocketService {
    private socket: Socket | null = null;
    private channel: any = null;
    private userId: string | null = null;
    private callbacks: {
        onMessage: ((message: SocketMessage) => void)[];
        onPlayerMove: ((data: { user_id: string; vec: [number, number, number] }) => void)[];
        onPlayerJoined: ((data: { user_id: string; vec: [number, number, number] }) => void)[];
        onPlayerAnimation: ((data: { user_id: string; animation: number }) => void)[];
        onPlayerFace: ((data: { user_id: string; face: number }) => void)[];
    } = {
            onMessage: [],
            onPlayerMove: [],
            onPlayerJoined: [],
            onPlayerAnimation: [],
            onPlayerFace: []
        };

    connect() {
        if (this.socket) return;

        this.socket = new Socket("/socket", { // ws://localhost:4000/socket
            params: { token: "user_token" }
        });

        this.socket.connect();

        this.channel = this.socket.channel("room:lobby", {
            greet: `Hello it's ${Date.now()}`,
            vec: [0, 0, 0]
        });

        this.channel.join()
            .receive("ok", (resp: any) => {
                console.log("Joined successfully", resp);
            })
            .receive("error", (resp: any) => {
                console.log("Unable to join", resp);
            });

        // Listen for messages
        this.channel.on(Pack.NEW_MESSAGE, (payload: SocketMessage) => {
            this.callbacks.onMessage.forEach(cb => cb(payload));
        });

        // Listen for player movements
        this.channel.on(Pack.MOVE, (payload: { user_id: string; vec: [number, number, number] }) => {
            this.callbacks.onPlayerMove.forEach(cb => cb(payload));
        });

        // Listen for new players joining
        this.channel.on(Pack.JOINED, (payload: { user_id: string; vec: [number, number, number] }) => {
            this.callbacks.onPlayerJoined.forEach(cb => cb(payload));
        });

        // Listen for animation changes
        this.channel.on(Pack.ANIMATION, (payload: { user_id: string; animation: number }) => {
            this.callbacks.onPlayerAnimation.forEach(cb => cb(payload));
        });

        // Listen for face changes
        this.channel.on(Pack.EXPRESSION, (payload: { user_id: string; face: number }) => {
            this.callbacks.onPlayerFace.forEach(cb => cb(payload));
        });
    }

    disconnect() {
        if (this.channel) {
            this.channel.leave();
        }
        if (this.socket) {
            this.socket.disconnect();
        }
        this.socket = null;
        this.channel = null;
    }

    sendMessage(body: string) {
        if (this.channel) {
            this.channel.push(Pack.NEW_MESSAGE, { body });
        }
    }

    sendMove(vec: [number, number, number]) {
        if (this.channel) {
            this.channel.push(Pack.MOVE, { vec });
        }
    }

    sendAnimation(animation: number) {
        if (this.channel) {
            this.channel.push(Pack.ANIMATION, { animation });
        }
    }

    sendFace(face: number) {
        if (this.channel) {
            this.channel.push(Pack.EXPRESSION, { face });
        }
    }

    onMessage(callback: (message: SocketMessage) => void) {
        this.callbacks.onMessage.push(callback);
    }

    onPlayerMove(callback: (data: { user_id: string; vec: [number, number, number] }) => void) {
        this.callbacks.onPlayerMove.push(callback);
    }

    onPlayerJoined(callback: (data: { user_id: string; vec: [number, number, number] }) => void) {
        this.callbacks.onPlayerJoined.push(callback);
    }

    onPlayerAnimation(callback: (data: { user_id: string; animation: number }) => void) {
        this.callbacks.onPlayerAnimation.push(callback);
    }

    onPlayerFace(callback: (data: { user_id: string; face: number }) => void) {
        this.callbacks.onPlayerFace.push(callback);
    }
}

export const socketService = new SocketService();
