"""
Plugin Demo per Stack4Things Lightning Rod

Questo è un esempio di plugin che può essere iniettato su una board virtuale.
Il plugin stampa un messaggio personalizzabile ogni secondo.

Per creare questo plugin tramite API:
    POST /v1/plugins
    {
        "name": "demo-plugin",
        "code": "<codice del plugin>",
        "parameters": {
            "message": "Hello from plugin!"
        }
    }

Per iniettare il plugin su una board:
    PUT /v1/boards/{board_id}/plugins/
    {
        "plugin": "<plugin_uuid>"
    }
"""

from iotronic_lightningrod.modules.plugins import Plugin

from oslo_log import log as logging

LOG = logging.getLogger(__name__)

# User imports
import time

class Worker(Plugin.Plugin):
    """
    Plugin Worker che stampa un messaggio personalizzabile.
    
    Parametri supportati:
        - message: Il messaggio da stampare (default: "Hello from plugin")
    """
    
    def __init__(self, uuid, name, q_result=None, params=None):
        super(Worker, self).__init__(uuid, name, q_result, params)

    def run(self):
        """
        Metodo principale del plugin.
        Viene eseguito quando il plugin viene avviato sulla board.
        """
        LOG.info("Plugin " + self.name + " starting...")
        LOG.info("Parameters: " + str(self.params))
        
        # Estrai il messaggio dai parametri, o usa un default
        if self.params and 'message' in self.params:
            message = self.params['message']
        else:
            message = "Hello from plugin " + self.name
        
        # Loop principale del plugin
        # Continua finché self._is_running è True
        while (self._is_running):
            print(message)
            LOG.info(message)
            time.sleep(1)
        
        LOG.info("Plugin " + self.name + " stopped.")

