# this matches the version you decided on from release notes
FROM i2incommon/grouper:2.5.39

# this will overlay all the files from the `opt` directory to `/opt/grouper/grouperWebapp/WEB-INF/classes/`
COPY slashRoot /

RUN chown -R tomcat:tomcat /opt/grouper \
 && chown -R tomcat:tomcat /opt/tomee