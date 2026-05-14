# Small AI in a Suitcase Platform

This is the supporting repository for Small AI in a Suitcase, an offline first, MIT App Inventor environment to create AI powered mobile apps.

Information about the suitcase and setup can be found in the [index file](./index.md).

The [./setup.sh](setup) script contains all the instructions to fully install the suitcase.
Running the script will set up all the software needed, including the MIT App Inventor sources and the servers to both host the mobile application development platform and the machine learning and computer vision training pipelines. The sources have been conveniently packaged in the form of containers, and will be automatically downloaded and configure through the script.

The following services will be available (offline when connected directly to the suitcase):

- MIT App Inventor mobile apps editor and build servers
- NGINX web server
- Llamacpp server and llama-swap
- Personal Image Classifier server and web UI

App Inventor Foundation, 2026
