# Small AI in a Suitcase Platform

This is the supporting repository for Small AI in a Suitcase, an offline first, MIT App Inventor environment to create AI powered mobile apps.

Small AI in a Suitcase – an offline-first platform for rapidly prototyping AI-powered mobile apps in low-resource, low-connectivity environments – was named a winner of the World Bank Group Innovation Award in 2026, recognizing early-stage innovations that accelerate the Bank's jobs and development priorities.

This project is a collaboration between the World Bank Group (Digital & AI, IFC/Knowledge Bank, People and Planet) and the App Inventor Foundation. The award reflects the World Bank Group's focus on bringing accessible, offline-first AI tools to frontline service delivery in low-resource settings.

Please open an issue in this repo or reach out to us if you have further questions.

Information about the suitcase and setup can be found in the [index file](./index.md).

The [./setup.sh](setup) script contains all the instructions to fully install the suitcase.
Running the script will set up all the software needed, including the MIT App Inventor sources and the servers to both host the mobile application development platform and the machine learning and computer vision training pipelines. The sources have been conveniently packaged in the form of containers, and will be automatically downloaded and configure through the script.

The following services will be available (offline when connected directly to the suitcase):

- MIT App Inventor mobile apps editor and build servers
- NGINX web server
- Llamacpp server and llama-swap
- Personal Image Classifier server and web UI

App Inventor Foundation, 2026
