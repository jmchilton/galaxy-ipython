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

galaxy_root_dir = os.path.abspath(trans.app.config.root)
history_id = trans.security.encode_id( trans.history.id )
dataset_id = trans.security.encode_id( hda.id )

config = ConfigParser.SafeConfigParser({'port': '8080'})
config.read( os.path.join( galaxy_root_dir, 'universe_wsgi.ini' ) )

galaxy_paster_port = config.getint('server:main', 'port')

# Find out where we are
viz_plugin_dir = config.get('app:main', 'visualization_plugins_directory')
if not os.path.isabs(viz_plugin_dir):
    # If it is NOT absolute, i.e. relative, append to galaxy root
    viz_plugin_dir = os.path.join(galaxy_root_dir, viz_plugin_dir)
# Get this plugin's directory
viz_plugin_dir = os.path.join(viz_plugin_dir, "ipython")
# Store our template and configuration path
our_config_dir = os.path.join(viz_plugin_dir, "config")
our_template_dir = os.path.join(viz_plugin_dir, "templates")
ipy_viz_config = ConfigParser.SafeConfigParser({'apache_urls': False, 'command': 'docker', 'image':
                                                'bgruening/docker-ipython-notebook',
                                                'password_auth': False})
ipy_viz_config.read( os.path.join( our_config_dir, "ipython.conf" ) )

# Ensure generation of notebook id is deterministic for the dataset. Replace with history id
# whenever we figure out how to access that.
random.seed( history_id )
notebook_id = ''.join(random.choice('0123456789abcdef') for _ in range(64))

with open( os.path.join( our_template_dir, 'notebook.ipynb' ), 'r') as nb_handle:
    empty_nb = nb_handle.read()
empty_nb = empty_nb % notebook_id


# Find all ports that are already occupied
cmd_netstat = shlex.split("netstat -tuln")
p1 = subprocess.Popen(cmd_netstat, stdout=subprocess.PIPE)

occupied_ports = set()
for line in p1.stdout.read().split('\n'):
    if line.startswith('tcp') or line.startswith('tcp6'):
        col = line.split()
        local_address = col[3]
        local_port = local_address.split(':')[-1]
        occupied_ports.add( int(local_port) )

# Generate random free port number for our docker container
while True:
    PORT = random.randrange(10000,15000)
    if PORT not in occupied_ports:
        break

HOST = request.host
# Strip out port, we just want the URL this galaxy server was accessed at.
if ':' in HOST:
    HOST = HOST[0:HOST.index(':')]

temp_dir = os.path.abspath( tempfile.mkdtemp() )


conf_file = {
    'history_id': history_id,
    'galaxy_url': request.application_url.rstrip('/'),
    'api_key': trans.user.api_keys[0].key,
    'remote_host': request.remote_addr,
    'galaxy_paster_port': galaxy_paster_port,
    'docker_port': PORT,
}

if ipy_viz_config.getboolean("main", "password_auth"):
    # Generate a random password + salt
    notebook_pw_salt = ''.join(random.choice('0123456789abcdefghijklmnopqrstuvwxyz') for _ in range(12))
    notebook_pw = ''.join(random.choice('0123456789abcdefghijklmnopqrstuvwxyz') for _ in range(24))
    m = hashlib.sha1()
    m.update( notebook_pw + notebook_pw_salt )
    conf_file['notebook_password'] = 'sha1:%s:%s' % (notebook_pw_salt, m.hexdigest())
    # Should we use password based connection or "default" connection style in galaxy
    password_auth_jsvar = "true"
else:
    notebook_pw = "None"
    password_auth_jsvar = "false"

# Write conf
with open( os.path.join( temp_dir, 'conf.yaml' ), 'wb' ) as handle:
    handle.write( yaml.dump(conf_file, default_flow_style=False) )

# Copy over default notebook, unless the dataset this viz is running on is a notebook
empty_nb_path = os.path.join(temp_dir, 'ipython_galaxy_notebook.ipynb')
if hda.datatype.__class__.__name__ != "Ipynb":
    with open( empty_nb_path, 'w+' ) as handle:
        handle.write( empty_nb )
else:
    shutil.copy( hda.file_name, empty_nb_path )

docker_cmd = '%s run -d --sig-proxy=true -p %s:6789 -v "%s:/import/" %s' % \
    (ipy_viz_config.get("docker", "command"), PORT, temp_dir, ipy_viz_config.get("docker", "image"))

# Access URLs for the notebook from within galaxy.
if ipy_viz_config.getboolean("main", "apache_urls"):
    notebook_access_url = "http://%s/ipython/%s/notebooks/ipython_galaxy_notebook.ipynb" % ( HOST, PORT )
    notebook_login_url = "http://%s/ipython/%s/login?next=%%2Fipython%%2F%s%%2Fnotebooks%%2Fipython_galaxy_notebook.ipynb" % ( HOST, PORT, PORT )
    apache_urls_jsvar = "true"
else:
    notebook_access_url = "http://%s:%s/ipython/%s/notebooks/ipython_galaxy_notebook.ipynb" % ( HOST, PORT, PORT )
    notebook_login_url = "http://%s:%s/ipython/%s/login?next=%%2Fipython%%2F%s%%2Fnotebooks%%2Fipython_galaxy_notebook.ipynb" % ( HOST, PORT, PORT, PORT )
    apache_urls_jsvar = "false"
subprocess.call(docker_cmd, shell=True)

# We need to wait until the Image and IPython in loaded
# TODO: This can be enhanced later, with some JS spinning if needed.
time.sleep(1)

%>
<html>
<head>
${h.css( 'base' ) }
${h.js( 'libs/jquery/jquery' ) }
${h.js( 'libs/toastr' ) }

</head>
<body>
<script type="text/javascript">
if ( ${ password_auth_jsvar } ) {
    // On document ready
    $( document ).ready(function() {
        // Make an AJAX POST
        $.ajax({
            type: "POST",
            // to the Login URL
            url: "${ notebook_login_url }",
            // With our password
            data: {
                'password': '${ notebook_pw }'
            },
            // If that is successful, load the notebook
            success: function(){
                //Append an object to the body
                $('body').append('<object data="${ notebook_access_url }" height="100%" width="100%">'
                +'<embed src="${ notebook_access_url }" height="100%" width="100%"/></object>'
                )
            },
            error: function(jqxhr, status, error){

                toastr.info(
                    "Automatic authorization failed. You can manually login with:<br>${ notebook_pw }<br> <a href='https://github.com/bgruening/galaxy-ipython' target='_blank'>More details ...</a>",
                    "Please login manually",
                    {'closeButton': true, 'timeOut': 100000, 'tapToDismiss': false}
                );

                if(${ password_auth_jsvar } && !${ apache_urls_jsvar }){
                    $('body').append('<object data="${ notebook_access_url }" height="100%" width="100%">'
                    +'<embed src="${ notebook_access_url }" height="100%" width="100%"/></object>'
                    )
                }else{
                    toastr.error(
                        "Could not connect to IPython Notebook. Please contact your administrator. <a href='https://github.com/bgruening/galaxy-ipython' target='_blank'>More details ...</a>",
                        "Security warning",
                        {'closeButton': true, 'timeOut': 20000, 'tapToDismiss': true}
                        );
                }
            }
        });
    });
}
else {
    // Not using password auth, just embed it to avoid content-origin issues.
    toastr.warning(
        "IPython Notebook was lunched wihtout authentication. This is a security issue. <a href='https://github.com/bgruening/galaxy-ipython' target='_blank'>More details ...</a>",
        "Security warning",
        {'closeButton': true, 'timeOut': 20000, 'tapToDismiss': false}
        );
    $( document ).ready(function() {
        $('body').append('<object data="${ notebook_access_url }" height="100%" width="100%">'
        +'<embed src="${ notebook_access_url }" height="100%" width="100%"/></object>'
        )
    });
}
</script>
</body>
</html>
