# Manual installation

In case the automated script doesn't work for you. 
Here's what the script does and must be done manually:

* **IIS Setup** will install all required features including IIS itself, as well
  as the URL Rewrite and Application Request Routing (ARR) modules. Furthermore,
  it will enable the reverse proxy capabilities.

  .. figure:: /_images/iis/iis-enable-proxy.png

  And set :guilabel:`preserveHostHeader` to :code:`true`. The most important
  configuration entries in IIS are the :guilabel:`Authentication` and
  :guilabel:`URL Rewrite` modules. The script will sense if IIS including all
  required features is already installed and will skip the IIS installation in
  that case. 

  .. figure:: /_images/iis/iis-overview.png
  

* **URL Rewrite Rules** configures the rules for URL rewriting. It will add a
  new rule :code:`ivy-route-all` to the :guilabel:`Default Website`. This will
  route all traffic to the Axon Ivy Engine which runs on the same host at
  :code:`http://localhost:8080`. You may adjust this rule according to your
  needs when your Axon Ivy Engine runs on a different host, and/or on a different
  port. We recommend to :ref:`limit the access <reverse-proxy-secure-path>` to
  specific applications by only routing the applications that are available to
  your users. You can do that by changing the standard pattern :code:`.*` of the
  rule to :code:`YOUR-APP.*` e.g., :code:`demo-portal.*`. e.g.,
  :code:`system.*`. If you have multiple apps being served by this IIS site, use
  a rule like :code:`(demo-portal|myApp1|myOtherApp)\/.*`. We suggest that you
  define a separate, internal-only website for access to the engine cockpit.
  
   .. figure:: /_images/iis/iis-url-rewrite.png

  There are features in Axon Ivy that require WebSocket communication. Therefore,
  we automatically install the WebSocket feature. IIS-ARR is not able to
  negotiate WebSocket compression, therefore we need to always set the HTTP
  header :code:`SEC_WEBSOCKET_EXTENSIONS` to empty. We implement that adding
  :code:`HTTP_SEC_WEBSOCKET_EXTENSIONS` to :guilabel:`IIS Server Variables` and
  setting :code:`HTTP_SEC_WEBSOCKET_EXTENSIONS` on the :code:`ivy-route-all`
  rewrite rule to empty.


* **Terminate SSL on IIS** ensures that IIS serves the Axon Ivy Engine over HTTPS
  but the connection between IIS and Axon Ivy Engine is HTTP only. We highly
  recommend to :ref:`setup your IIS this way <reverse-proxy-terminate-ssl>`.
  This will create a new :guilabel:`IIS Server Variable` called
  :code:`HTTP_X-Forwarded-Proto` that will be set to :code:`https` on the
  :code:`ivy-route-all` rewrite rule. This will send the HTTP header
  :code:`X-Forwarded-Proto` from IIS to the Axon Ivy Engine. The Axon Ivy Engine needs
  this information to generate correct URLs.

  .. figure:: /_images/iis/iis-terminate-ssl-server-variable.png

  .. figure:: /_images/iis/iis-terminate-ssl-port.png

* **Setup SSO** will configure :ref:`Single Sign-on <single-sign-on>`. This will
  enable Windows Authentication and will add a HTTP request header
  :code:`X-Forwarded-User` with the current user to the request that will be
  forwarded to the Axon Ivy Engine. You will also need to :ref:`activate Single
  Sign-on <single-sign-on>` on the Axon Ivy Engine in :code:`ivy.yaml`. The script will also
  enable Basic Authentication which is required for REST clients like the
  Axon Ivy Mobile App to call the protected REST Services provided by the
  Axon Ivy Engine. If you don't need this you can manually disable it.

  .. warning::

    If you enable SSO, you need to make sure that your users can access the
    Axon Ivy Engine :ref:`exclusively via IIS <single-sign-on>`.

  .. figure:: /_images/iis/iis-authentication.png



* **Serve with HTTPS** is not covered by this script. You need to set this up
  manually. You need to install an SSL certificate. You can do this on the server
  level in section :guilabel:`Server Certificate`. Import your SSL certificate
  there. Alternatively, you can generate a self-signed certificate to try out
  HTTPS.  

  .. figure:: /_images/iis/iis-https-certificate.png

  Then, go to :guilabel:`Default Website`, open :guilabel:`Handler Mappings` and
  add :code:`https` as a new binding. Choose the SSL certificate you supplied
  earlier. We strongly recommend to remove the :code:`http` binding. This prevents your
  Axon Ivy Engine being accessible via HTTP through IIS.

  .. figure:: /_images/iis/iis-https-binding.png
