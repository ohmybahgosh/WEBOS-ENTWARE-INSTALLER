// The app has to run on old webOS browsers, so it's held to ES5: any newer
// syntax (let, const, arrow functions, template strings) fails the lint.
export default [
    {
        files: ['src/**/*.js'],
        languageOptions: {
            ecmaVersion: 5,
            sourceType: 'script',
            globals: {
                window: 'readonly', document: 'readonly', XMLHttpRequest: 'readonly',
                setTimeout: 'readonly', clearTimeout: 'readonly', setInterval: 'readonly',
                encodeURIComponent: 'readonly', decodeURIComponent: 'readonly',
                JSON: 'readonly', Math: 'readonly', Array: 'readonly', String: 'readonly', parseInt: 'readonly'
            }
        },
        rules: {
            'no-undef': 'error',
            // ES5 has no catch without a name, so unused catch names are fine
            'no-unused-vars': ['error', { caughtErrors: 'none' }],
            'no-redeclare': 'error',
            'no-dupe-keys': 'error',
            'no-unreachable': 'error',
            'no-implicit-globals': 'error',
            'no-eval': 'error',
            'no-implied-eval': 'error',
            'no-new-func': 'error',
            eqeqeq: ['error', 'smart'],
            strict: ['error', 'function']
        }
    }
];
