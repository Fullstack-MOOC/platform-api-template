/* eslint-disable import/extensions */
/* eslint-disable global-require */
const { defineConfig } = require('cypress');

module.exports = defineConfig({
  video: false,
  screenshotOnRunFailure: false,
  e2e: {
    setupNodeEvents(on, config) {
      return require('./cypress/plugins/index.js')(on, config);
    },
    baseUrl: 'http://localhost:9090',
  },
});
