*** Settings ***
Suite Setup     Setup
Suite Teardown  Teardown
Test Teardown   Test Teardown
Resource        ${RENODEKEYWORDS}

*** Test Cases ***
Should Print Help
    ${x}=  Execute Command     help
           Should Contain      ${x}    Available commands:
               

Should Print Path
    ${x}=  Execute Command     help path
           Should Contain      ${x}    Available commands:
               

Should Run Keystone
    ${x}=  Execute Command     help path
           Execute Command     s @renode.build/keystone_unleashed.resc
           Should Contain      ${x}    buildroot
