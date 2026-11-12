const lwcConfig = require('@salesforce/eslint-config-lwc');

module.exports = [
  {
    ignores: ['node_modules/**', 'coverage/**', 'force-app/main/default/staticresources/**']
  },
  ...lwcConfig.configs.recommended
];
