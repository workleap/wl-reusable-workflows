import { ApiCheck, AssertionBuilder } from 'checkly/constructs'

const cortexTags: string[] = []; // Do not edit. Updated automatically at publish time

new ApiCheck('dummy-api', {
  name: 'dummy',
  degradedResponseTime: 5000,
  maxResponseTime: 10000,
  tags: [...cortexTags],
  request: {
    method: 'GET',
    url: 'https://dummy/health',
    skipSSL: true,
    assertions: [
      AssertionBuilder.statusCode().equals(200),
    ]
  }
})

