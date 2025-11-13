# Contributing to Frugal Onboarding Scripts

Thank you for your interest in contributing to Frugal's onboarding scripts! We welcome contributions from the community.

## How to Contribute

### Reporting Issues

If you encounter a bug or have a feature request:

1. Check if the issue already exists in [Issues](https://github.com/frugalco/frugal-onboarding/issues)
2. If not, create a new issue with:
   - Clear description of the problem or feature
   - Steps to reproduce (for bugs)
   - Expected vs actual behavior
   - Your environment (OS, cloud provider, relevant versions)

### Contributing Code

We follow a **fork and pull request** workflow:

#### 1. Fork the Repository

Click the "Fork" button at the top of this repository to create your own copy.

#### 2. Clone Your Fork

```bash
git clone https://github.com/YOUR-USERNAME/frugal-onboarding.git
cd frugal-onboarding
```

#### 3. Create a Feature Branch

```bash
git checkout -b fix/description-of-fix
# or
git checkout -b feature/description-of-feature
```

Branch naming conventions:
- `fix/` - Bug fixes
- `feature/` - New features
- `docs/` - Documentation updates

#### 4. Make Your Changes

**For Scripts:**
- Follow the existing code style and patterns
- Add comments for complex logic
- Test your changes thoroughly
- Ensure the script works on multiple platforms if applicable

**For Documentation:**
- Use clear, concise language
- Include examples where helpful
- Update all relevant README files

#### 5. Test Your Changes

Before submitting, test your changes:

```bash
# For shell scripts, check syntax
bash -n path/to/your-script.sh

# Test the script in a safe environment
# (e.g., test AWS account, GCP project)
./path/to/your-script.sh --help
```

#### 6. Commit Your Changes

Write clear, descriptive commit messages:

```bash
git add .
git commit -m "fix: correct permission issue in AWS setup

- Update IAM policy to include missing CloudWatch permission
- Add validation check for policy attachment
- Update README with new prerequisites"
```

Commit message format:
- `fix:` - Bug fixes
- `feat:` - New features
- `docs:` - Documentation changes
- `style:` - Code style changes (formatting, no logic change)
- `refactor:` - Code refactoring
- `test:` - Adding or updating tests

#### 7. Push to Your Fork

```bash
git push origin fix/description-of-fix
```

#### 8. Create a Pull Request

1. Go to your fork on GitHub
2. Click "Pull Request"
3. Select your branch
4. Fill out the PR template with:
   - Description of changes
   - Why the change is needed
   - Testing performed
   - Any breaking changes

### Pull Request Guidelines

**Good PRs:**
- ✅ Focus on a single issue or feature
- ✅ Include tests or testing steps
- ✅ Update relevant documentation
- ✅ Follow existing code style
- ✅ Have clear commit messages

**Avoid:**
- ❌ Mixing multiple unrelated changes
- ❌ Breaking existing functionality
- ❌ Adding dependencies without discussion
- ❌ Committing credentials or secrets

### Code Review Process

1. Maintainers will review your PR
2. You may be asked to make changes
3. Once approved, your PR will be squash-merged
4. Your branch will be automatically deleted

## Development Guidelines

### Shell Script Best Practices

1. **Portability**: Scripts should work on macOS and Linux
2. **Error Handling**: Use `set -e` and check command results
3. **User Experience**: Provide clear output and error messages
4. **Safety**: Use `--undo` functionality for cleanup
5. **Documentation**: Comment complex logic

### Security

**Never commit:**
- Credentials or API keys
- Service account keys
- Tokens or passwords
- Customer data

**Always:**
- Use placeholder values in examples
- Follow the principle of least privilege
- Document security implications

### Testing Checklist

Before submitting, verify:

- [ ] Script runs without errors
- [ ] Help text (`--help`) is clear and accurate
- [ ] `--undo` functionality works (if applicable)
- [ ] No hardcoded credentials or secrets
- [ ] Documentation is updated
- [ ] Works on both macOS and Linux (if applicable)
- [ ] No breaking changes to existing functionality

## What We're Looking For

### Welcome Contributions

- Bug fixes and error handling improvements
- Documentation improvements and clarifications
- Support for additional cloud services
- Enhanced error messages and user feedback
- Platform compatibility fixes
- Security improvements

### Needs Discussion First

These require discussion before submitting a PR:

- Major architectural changes
- New dependencies
- Breaking changes to existing scripts
- New cloud provider support

**Please open an issue first to discuss!**

## Questions?

- Open an issue for questions about contributing
- Check existing issues and PRs for similar discussions
- Review the README files in each provider directory

## License

By contributing, you agree that your contributions will be licensed under the same [MIT License](LICENSE) that covers this project.

## Thank You!

Your contributions help make cloud onboarding easier for everyone. We appreciate your time and effort!
