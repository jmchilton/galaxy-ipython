<%
import os
import sys
import time
import yaml
import shlex
import random
import shutil
import hashlib
import tempfile
import subprocess
import ConfigParser

def get_galaxy_paster_port():
    # Galaxy config parser
    config = ConfigParser.SafeConfigParser({'port': '8080'})
    config.read( os.path.join( galaxy_root_dir, 'universe_wsgi.ini' ) )

    # uWSGI galaxy installations don't use paster and only speak uWSGI not http
    try:
        port = config.getint('server:%s' % galaxy_config.server_name, 'port')
    except:
        port = None
    return port

def load_notebook():
    notebook_id = ''.join(random.choice('0123456789abcdef') for _ in range(64))
    with open( os.path.join( our_template_dir, 'notebook.ipynb' ), 'r') as nb_handle:
        empty_nb = nb_handle.read()
    empty_nb = empty_nb % notebook_id
    return empty_nb

def generate_pasword(length=12):
    return ''.join(random.choice('0123456789abcdefghijklmnopqrstuvwxyz') for _ in range(length))

def javascript_boolean(boolean):
    """
        Convenience function to convert boolean for use in JS
    """
    return "true" if boolean else "false"


galaxy_config = trans.app.config
galaxy_root_dir = os.path.abspath(galaxy_config.root)
history_id = trans.security.encode_id( trans.history.id )
# Routes
root        = h.url_for( "/" )
app_root    = root + "plugins/visualizations/ipython/static/"

galaxy_paster_port = get_galaxy_paster_port()

# Store our template and configuration path
our_config_dir = os.path.join(plugin_path, "config")
our_template_dir = os.path.join(plugin_path, "templates")
ipy_viz_config = ConfigParser.SafeConfigParser({'apache_urls': False, 'command': 'docker', 'image':
                                                'bgruening/docker-ipython-notebook',
                                                'password_auth': False, 'ssl': False,
                                                'docker_delay': 1})
ipy_viz_config.read( os.path.join( our_config_dir, "ipython.conf" ) )

PASSWORD_AUTH = ipy_viz_config.getboolean("main", "password_auth")
APACHE_URLS = ipy_viz_config.getboolean("main", "apache_urls")
SSL_URLS = ipy_viz_config.getboolean("main", "ssl")
proxy_request = trans.app.proxy_manager.setup_proxy( trans )  
PORT = proxy_request[ 'proxied_port' ]
HOST = request.host
# Strip out port, we just want the URL this galaxy server was accessed at.
if ':' in HOST:
    HOST = HOST[0:HOST.index(':')]

temp_dir = os.path.abspath( tempfile.mkdtemp() )
api_key = get_api_key()

conf_file = {
    'history_id': history_id,
    'galaxy_url': request.application_url.rstrip('/') + '/',
    'api_key': api_key,
    'remote_host': request.remote_addr,
    'galaxy_paster_port': galaxy_paster_port,
    'docker_port': PORT,
    'cors_origin': request.host_url,
}

if PASSWORD_AUTH:
    # Generate a random password + salt
    notebook_pw_salt = generate_pasword(length=12)
    notebook_pw = generate_pasword(length=24)
    m = hashlib.sha1()
    m.update( notebook_pw + notebook_pw_salt )
    conf_file['notebook_password'] = 'sha1:%s:%s' % (notebook_pw_salt, m.hexdigest())
    # Should we use password based connection or "default" connection style in galaxy
else:
    notebook_pw = "None"

# Write conf
with open( os.path.join( temp_dir, 'conf.yaml' ), 'wb' ) as handle:
    handle.write( yaml.dump(conf_file, default_flow_style=False) )

# Prepare an empty notebook
empty_nb = load_notebook()
# Copy over default notebook, unless the dataset this viz is running on is a notebook
empty_nb_path = os.path.join(temp_dir, 'ipython_galaxy_notebook.ipynb')
if hda.datatype.__class__.__name__ != "Ipynb":
    with open( empty_nb_path, 'w+' ) as handle:
        handle.write( empty_nb )
else:
    shutil.copy( hda.file_name, empty_nb_path )

docker_cmd = '%s run -d --sig-proxy=true -p %s:6789 -v "%s:/import/" %s' % \
    (ipy_viz_config.get("docker", "command"), PORT, temp_dir, ipy_viz_config.get("docker", "image"))

notebook_access_url = "%s/ipython/%s/notebooks/ipython_galaxy_notebook.ipynb" % ( proxy_request[ 'proxy_url' ], PORT )
notebook_login_url = "%s/ipython/%s/login" % ( proxy_request[ 'proxy_url' ], PORT )
subprocess.call(docker_cmd, shell=True)

%>
<html>
<head>
${h.css( 'base' ) }
${h.js( 'libs/jquery/jquery' ) }
${h.js( 'libs/toastr' ) }
## Load IPython-Galaxy connector
${h.javascript_link( app_root + 'ipy-galaxy.js' )}
</head>
<body>

<script type="text/javascript">
var password_auth = ${ javascript_boolean(PASSWORD_AUTH) };
var apache_urls = ${ javascript_boolean(APACHE_URLS) };
var notebook_login_url = '${ notebook_login_url }';
var password = '${ notebook_pw }';
var notebook_access_url = '${ notebook_access_url }';
var galaxy_root = '${ root }';
// Load notebook
load_notebook(password_auth, password, notebook_login_url, notebook_access_url, apache_urls, galaxy_root);
</script>

<div id="main" width="100%" height="100%">
</div>

</body>
</html>
