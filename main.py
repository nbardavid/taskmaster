#!/usr/bin/env python3
import os
import socket
import sys
import signal
import struct

SOCKET_PATH = "/tmp/taskmaster.server.sock"
CONFIG_FILE = os.path.join(os.path.dirname(__file__), "config.json")

def send_config(conn):
    # Lire le contenu de config.json
    try:
        with open(CONFIG_FILE, "rb") as f:
            payload = f.read()
    except FileNotFoundError:
        print(f"Erreur : {CONFIG_FILE} introuvable.")
        payload = b"{}"

    # Construire l'entête (1 byte commandId, 1 byte reserved, 2 bytes length little endian)
    command_id = 0   # config
    reserved = 0
    length = len(payload)
    header = struct.pack("<BBH", command_id, reserved, length)

    print("sending header:", header, "len(payload)=", len(payload))

    # Envoyer header + payload
    conn.sendall(header + payload)
    print(f"Config envoyée ({length} bytes).")

def main():
    # Supprimer l’ancien socket s’il existe
    if os.path.exists(SOCKET_PATH):
        os.remove(SOCKET_PATH)

    # Créer le socket Unix
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(SOCKET_PATH)
    server.listen(1)

    print(f"Serveur prêt sur {SOCKET_PATH}, en attente d’un client...")

    def cleanup(*_):
        print("\nArrêt du serveur...")
        server.close()
        if os.path.exists(SOCKET_PATH):
            os.remove(SOCKET_PATH)
        sys.exit(0)

    signal.signal(signal.SIGINT, cleanup)
    signal.signal(signal.SIGTERM, cleanup)

    while True:
        conn, _ = server.accept()
        print("Client connecté !")

        # envoyer la config une fois à la connexion
        send_config(conn)

        # garder la connexion ouverte pour tests
        try:
            while True:
                data = conn.recv(1024)
                if not data:
                    print("Client déconnecté.")
                    break
                print("Reçu du client:", data)
                # tu pourrais renvoyer des commandes ou ack ici si besoin
        finally:
            conn.close()

if __name__ == "__main__":
    main()
