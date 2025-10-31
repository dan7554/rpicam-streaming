import { useState, useEffect, useRef } from 'react';
import { io } from 'socket.io-client';

export const useWebSocket = () => {
  const [socket, setSocket] = useState(null);
  const [connected, setConnected] = useState(false);
  const [error, setError] = useState(null);
  const socketRef = useRef(null);

  useEffect(() => {
    // Use Vite environment variables
    const serverUrl = import.meta.env.VITE_SERVER_URL || 'http://localhost:3001';
    
    // Initialize socket connection
    const newSocket = io(serverUrl, {
      transports: ['websocket', 'polling'],
      timeout: 20000,
      forceNew: true,
    });

    socketRef.current = newSocket;

    newSocket.on('connect', () => {
      console.log('Connected to server');
      setConnected(true);
      setError(null);
    });

    newSocket.on('disconnect', (reason) => {
      console.log('Disconnected from server:', reason);
      setConnected(false);
    });

    newSocket.on('connect_error', (error) => {
      console.error('Connection error:', error);
      setConnected(false);
      setError(error?.message || 'Connection failed');
    });

    newSocket.on('error', (error) => {
      console.error('Socket error:', error);
      setError(error?.message || 'Socket error occurred');
    });

    setSocket(newSocket);

    return () => {
      if (socketRef.current) {
        socketRef.current.disconnect();
      }
    };
  }, []);

  const emit = (event, data) => {
    if (socket && connected && event) {
      socket.emit(event, data);
    }
  };

  const on = (event, callback) => {
    if (socket && event && typeof callback === 'function') {
      socket.on(event, callback);
    }
  };

  const off = (event, callback) => {
    if (socket && event) {
      if (callback && typeof callback === 'function') {
        socket.off(event, callback);
      } else {
        socket.off(event);
      }
    }
  };

  return {
    socket,
    connected,
    error,
    emit,
    on,
    off,
  };
};