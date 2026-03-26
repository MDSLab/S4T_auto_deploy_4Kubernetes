#!/usr/bin/env python3
"""
Load Balancer IoT Minimale - Deploy funzioni Nuclio
Supporta deploy da codice inline e da repository GitHub
"""
 
from flask import Flask, request, jsonify
import requests
import logging
import random
 
# Setup logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)
 
app = Flask(__name__)
 
# Lista dei nodi IoT (edge workers)
NODES = [
    "http://10.42.0.21:50031",  # Proxy 1
    "http://10.42.0.21:50038",  # Proxy 2
]
 
current_node = 0  # Round robin semplice
 
def get_next_node():
    """Seleziona il nodo con meno funzioni deployate (load-aware round robin)"""
    nodes_load = []
 
    for node in NODES:
        try:
            response = requests.get(f"{node}/functions", timeout=5)
            if response.status_code == 200:
                functions = response.json()
                num_functions = len(functions) if isinstance(functions, list) else 0
                nodes_load.append((node, num_functions))
            else:
                logger.warning(f"Nodo {node} non ha risposto correttamente a /functions")
        except Exception as e:
            logger.warning(f"Errore contattando il nodo {node}: {e}")
            continue
 
    if not nodes_load:
        return None  # Nessun nodo disponibile
 
    # Trova il minimo carico
    min_count = min(load for _, load in nodes_load)
    least_loaded_nodes = [node for node, count in nodes_load if count == min_count]
 
    # Se più nodi hanno lo stesso carico minimo, sceglili a caso (round robin opzionale)
    selected_node = random.choice(least_loaded_nodes)
    return selected_node
 
@app.route('/deploy', methods=['POST'])
def deploy_function():
    """Deploy una funzione da codice inline su un nodo IoT"""
    try:
        # Seleziona il nodo
        node_url = get_next_node()
        if not node_url:
            return jsonify({'error': 'Nessun nodo disponibile'}), 503
 
        # Ottieni i dati della funzione
        function_data = request.get_json()
        if not function_data:
            return jsonify({'error': 'Dati funzione mancanti'}), 400
 
        logger.info(f"Deploy su nodo: {node_url}")
        logger.info(f"Dati funzione: {function_data}")
 
        # Inoltra la richiesta al nodo (endpoint /deploy)
        response = requests.post(
            f"{node_url}/deploy",
            json=function_data,
            timeout=30
        )
 
        # Restituisci la risposta
        return jsonify({
            'status': 'success' if response.status_code == 200 else 'error',
            'node': node_url,
            'response': response.json() if response.headers.get('content-type', '').startswith('application/json') else response.text
        }), response.status_code
 
    except requests.exceptions.RequestException as e:
        logger.error(f"Errore nella richiesta: {e}")
        return jsonify({'error': 'Errore di connessione al nodo'}), 502
    except Exception as e:
        logger.error(f"Errore generico: {e}")
        return jsonify({'error': 'Errore interno'}), 500
 
@app.route('/deploy-github', methods=['POST'])
def deploy_function_from_github():
    """Deploy una funzione da repository GitHub su un nodo IoT"""
    try:
        # Seleziona il nodo
        node_url = get_next_node()
        if not node_url:
            return jsonify({'error': 'Nessun nodo disponibile'}), 503
 
        # Ottieni i dati della funzione GitHub
        github_data = request.get_json()
        if not github_data:
            return jsonify({'error': 'Dati GitHub mancanti'}), 400
 
        # Validazione dati GitHub
        required_fields = ['name', 'githubUrl']
        missing_fields = [field for field in required_fields if field not in github_data]
        if missing_fields:
            return jsonify({'error': f'Campi mancanti: {", ".join(missing_fields)}'}), 400
 
        logger.info(f"Deploy GitHub su nodo: {node_url}")
        logger.info(f"Dati GitHub: {github_data}")
 
        # Inoltra la richiesta al nodo (endpoint /deploy-github)
        response = requests.post(
            f"{node_url}/deploy-github",
            json=github_data,
            timeout=120  # Timeout più lungo per GitHub
        )
 
        # Restituisci la risposta
        return jsonify({
            'status': 'success' if response.status_code == 200 else 'error',
            'node': node_url,
            'response': response.json() if response.headers.get('content-type', '').startswith('application/json') else response.text
        }), response.status_code
 
    except requests.exceptions.RequestException as e:
        logger.error(f"Errore nella richiesta GitHub: {e}")
        return jsonify({'error': 'Errore di connessione al nodo'}), 502
    except Exception as e:
        logger.error(f"Errore generico GitHub: {e}")
        return jsonify({'error': 'Errore interno'}), 500
 
@app.route('/status', methods=['GET'])
def get_status():
    """Status del load balancer"""
    return jsonify({
        'status': 'running',
        'nodes': NODES,
        'current_node_index': current_node,
        'supported_endpoints': [
            '/deploy - Deploy da codice inline',
            '/deploy-github - Deploy da repository GitHub',
            '/status - Status del load balancer'
        ]
    })
 
@app.route('/deploy-github-to', methods=['POST'])
def deploy_github_to_specific_node():
    """Deploy da GitHub su un nodo specifico"""
    try:
        data = request.get_json()
        if not data or 'nodeUrl' not in data:
            return jsonify({'error': 'Campo "nodeUrl" mancante'}), 400
 
        node_url = data.pop('nodeUrl')
        logger.info(f"Deploy GitHub mirato su nodo: {node_url}")
 
        response = requests.post(f"{node_url}/deploy-github", json=data, timeout=120)
 
        return jsonify({
            'status': 'success' if response.status_code == 200 else 'error',
            'node': node_url,
            'response': response.json() if response.headers.get('content-type', '').startswith('application/json') else response.text
        }), response.status_code
 
    except requests.exceptions.RequestException as e:
        logger.error(f"Errore nella richiesta GitHub al nodo: {e}")
        return jsonify({'error': 'Errore di connessione al nodo'}), 502
    except Exception as e:
        logger.error(f"Errore generico GitHub: {e}")
        return jsonify({'error': 'Errore interno'}), 500
    
@app.route('/deploy-to', methods=['POST'])
def deploy_to_specific_node():
    """Deploya una funzione su un nodo specifico"""
    try:
        data = request.get_json()
        if not data or 'nodeUrl' not in data:
            return jsonify({'error': 'Campo "nodeUrl" mancante'}), 400
 
        node_url = data.pop('nodeUrl')
        logger.info(f"Deploy mirato su nodo: {node_url}")
 
        response = requests.post(f"{node_url}/deploy", json=data, timeout=30)
 
        return jsonify({
            'status': 'success' if response.status_code == 200 else 'error',
            'node': node_url,
            'response': response.json() if response.headers.get('content-type', '').startswith('application/json') else response.text
        }), response.status_code
 
    except requests.exceptions.RequestException as e:
        logger.error(f"Errore nella richiesta al nodo: {e}")
        return jsonify({'error': 'Errore di connessione al nodo'}), 502
    except Exception as e:
        logger.error(f"Errore generico: {e}")
        return jsonify({'error': 'Errore interno'}), 500

@app.route('/nodes/health', methods=['GET'])
def check_nodes_health():
    """Verifica lo stato di salute di tutti i nodi"""
    nodes_status = []
 
    for node in NODES:
        try:
            response = requests.get(f"{node}/health", timeout=5)
            nodes_status.append({
                'node': node,
                'status': 'healthy' if response.status_code == 200 else 'unhealthy',
                'response_time': response.elapsed.total_seconds(),
                'details': response.json() if response.headers.get('content-type', '').startswith('application/json') else response.text
            })
        except requests.exceptions.RequestException as e:
            nodes_status.append({
                'node': node,
                'status': 'unreachable',
                'error': str(e)
            })
 
    return jsonify({
        'total_nodes': len(NODES),
        'healthy_nodes': len([n for n in nodes_status if n['status'] == 'healthy']),
        'nodes': nodes_status
    })
 
if __name__ == '__main__':
    logger.info("Avvio Load Balancer minimale...")
    logger.info(f"Nodi configurati: {NODES}")
    logger.info("Endpoints disponibili:")
    logger.info("  POST /deploy - Deploy da codice inline")
    logger.info("  POST /deploy-github - Deploy da repository GitHub")
    logger.info("  POST /deploy-to - Deploy da codice inline su un nodo specifico")
    logger.info("  POST /deploy-github-to - Deploy da repository GitHub su un nodo specifico")
    logger.info("  GET /status - Status del load balancer")
    logger.info("  GET /nodes/health - Health check di tutti i nodi")
 
    app.run(
        host='0.0.0.0',
        port=5002,
        debug=False
    )
