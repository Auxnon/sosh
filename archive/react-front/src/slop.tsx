import React, { useState, useEffect, useRef } from 'react';
import * as THREE from 'three';
import { Settings, MessageSquare, ChevronLeft, ChevronRight, X } from 'lucide-react';

export default function ThreeDChatInterface() {
  const [chatPosition, setChatPosition] = useState('right'); // 'left', 'right', 'center'
  const [isChatVisible, setIsChatVisible] = useState(true);
  const [isMobile, setIsMobile] = useState(false);
  const canvasRef = useRef(null);
  const sceneRef = useRef(null);
  const cameraRef = useRef(null);
  const rendererRef = useRef(null);
  const cubeRef = useRef(null);

  // Check if device is mobile
  useEffect(() => {
    const checkIfMobile = () => {
      setIsMobile(window.innerWidth < 768);
    };
    
    checkIfMobile();
    window.addEventListener('resize', checkIfMobile);
    
    return () => {
      window.removeEventListener('resize', checkIfMobile);
    };
  }, []);

  // Initialize Three.js scene
  useEffect(() => {
    if (!canvasRef.current) return;
    
    // Initialize scene
    const scene = new THREE.Scene();
    scene.background = new THREE.Color(0x121212);
    sceneRef.current = scene;
    
    // Initialize camera
    const camera = new THREE.PerspectiveCamera(75, window.innerWidth / window.innerHeight, 0.1, 1000);
    camera.position.z = 5;
    cameraRef.current = camera;
    
    // Initialize renderer
    const renderer = new THREE.WebGLRenderer({ canvas: canvasRef.current, antialias: true });
    renderer.setSize(window.innerWidth, window.innerHeight);
    rendererRef.current = renderer;
    
    // Add cube
    const geometry = new THREE.BoxGeometry(2, 2, 2);
    const material = new THREE.MeshNormalMaterial();
    const cube = new THREE.Mesh(geometry, material);
    scene.add(cube);
    cubeRef.current = cube;
    
    // Add ambient light
    const ambientLight = new THREE.AmbientLight(0xffffff, 0.5);
    scene.add(ambientLight);
    
    // Add directional light
    const directionalLight = new THREE.DirectionalLight(0xffffff, 1);
    directionalLight.position.set(5, 5, 5);
    scene.add(directionalLight);
    
    // Handle window resize
    const handleResize = () => {
      if (cameraRef.current && rendererRef.current) {
        cameraRef.current.aspect = window.innerWidth / window.innerHeight;
        cameraRef.current.updateProjectionMatrix();
        rendererRef.current.setSize(window.innerWidth, window.innerHeight);
      }
    };
    
    window.addEventListener('resize', handleResize);
    
    // Animation loop
    const animate = () => {
      requestAnimationFrame(animate);
      
      if (cubeRef.current) {
        cubeRef.current.rotation.x += 0.01;
        cubeRef.current.rotation.y += 0.01;
      }
      
      if (rendererRef.current && sceneRef.current && cameraRef.current) {
        rendererRef.current.render(sceneRef.current, cameraRef.current);
      }
    };
    
    animate();
    
    return () => {
      window.removeEventListener('resize', handleResize);
      scene.remove(cube);
      geometry.dispose();
      material.dispose();
      renderer.dispose();
    };
  }, []);

  const toggleChatVisibility = () => {
    setIsChatVisible(!isChatVisible);
  };

  const changeChatPosition = (position) => {
    setChatPosition(position);
  };

  return (
    <div className="relative w-full h-screen overflow-hidden">
      {/* 3D Canvas */}
      <canvas ref={canvasRef} className="w-full h-full block" />

      {/* Chat Window */}
      {isChatVisible && (
        <div 
          className={`absolute bg-slate-800 text-white rounded-lg shadow-lg flex flex-col
            ${isMobile 
              ? 'bottom-0 left-0 right-0 h-1/2 rounded-b-none' 
              : chatPosition === 'left' 
                ? 'left-4 bottom-4 top-4 w-80' 
                : chatPosition === 'right' 
                  ? 'right-4 bottom-4 top-4 w-80' 
                  : 'left-1/2 -translate-x-1/2 bottom-4 w-1/2 h-2/3'
            }`}
        >
          {/* Chat Header */}
          <div className="flex items-center justify-between p-4 border-b border-slate-700">
            <div className="flex items-center">
              <MessageSquare className="mr-2" size={20} />
              <h3 className="font-medium">Chat Window</h3>
            </div>
            <div className="flex items-center">
              {!isMobile && (
                <div className="flex mr-2 bg-slate-700 rounded-md">
                  <button 
                    onClick={() => changeChatPosition('left')}
                    className={`p-1 rounded-l-md ${chatPosition === 'left' ? 'bg-blue-600' : ''}`}
                    title="Position Left"
                  >
                    <ChevronLeft size={16} />
                  </button>
                  <button 
                    onClick={() => changeChatPosition('center')}
                    className={`p-1 ${chatPosition === 'center' ? 'bg-blue-600' : ''}`}
                    title="Position Center"
                  >
                    <Settings size={16} />
                  </button>
                  <button 
                    onClick={() => changeChatPosition('right')}
                    className={`p-1 rounded-r-md ${chatPosition === 'right' ? 'bg-blue-600' : ''}`}
                    title="Position Right"
                  >
                    <ChevronRight size={16} />
                  </button>
                </div>
              )}
              <button 
                onClick={toggleChatVisibility}
                className="p-1 rounded-md hover:bg-slate-700"
                title="Close Chat"
              >
                <X size={16} />
              </button>
            </div>
          </div>

          {/* Chat Messages */}
          <div className="flex-1 overflow-y-auto p-4 space-y-4">
            <div className="bg-slate-700 p-3 rounded-lg max-w-xs">
              Hello! This is a sample message.
            </div>
            <div className="bg-blue-600 p-3 rounded-lg max-w-xs ml-auto">
              This is a response message.
            </div>
            <div className="bg-slate-700 p-3 rounded-lg max-w-xs">
              You can interact with the 3D scene while chatting.
            </div>
          </div>

          {/* Chat Input */}
          <div className="p-4 border-t border-slate-700">
            <div className="flex items-center bg-slate-700 rounded-full">
              <input 
                type="text" 
                className="flex-1 bg-transparent p-3 outline-none" 
                placeholder="Type your message..."
              />
              <button className="bg-blue-600 text-white p-2 rounded-full mr-1">
                <svg xmlns="http://www.w3.org/2000/svg" width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
                  <line x1="22" y1="2" x2="11" y2="13"></line>
                  <polygon points="22 2 15 22 11 13 2 9 22 2"></polygon>
                </svg>
              </button>
            </div>
          </div>
        </div>
      )}

      {/* Toggle Chat Button (when chat is hidden) */}
      {!isChatVisible && (
        <button
          onClick={toggleChatVisibility}
          className="absolute bottom-4 right-4 bg-blue-600 text-white p-3 rounded-full shadow-lg"
        >
          <MessageSquare size={24} />
        </button>
      )}
    </div>
  );
}
