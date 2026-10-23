"""Run the actual QA path predicate with the verified installed PHP CLI."""
import argparse
from pathlib import Path
import subprocess


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--php-executable', type=Path, required=True)
    args = parser.parse_args()
    php = args.php_executable
    if not php.is_absolute() or not php.is_file() or php.is_symlink():
        raise ValueError('An explicit ordinary installed PHP executable is required.')
    version = subprocess.run([str(php), '-n', '-r', 'echo PHP_VERSION;'],
                             capture_output=True, timeout=5, check=True)
    if version.stdout != b'8.4.27' or version.stderr:
        raise ValueError('The qualified installed PHP version is required.')
    result = subprocess.run([str(php), '-n', str(Path(__file__).with_name('windows_welcome_path_tests.php'))],
                            capture_output=True, timeout=10, check=True)
    expected = (b'PASS 15 actual PHP welcome-path controls; normalized-path fixture only, '
                b'native dispatch unqualified\n')
    if result.stdout != expected or result.stderr:
        raise ValueError('The complete actual PHP path controls did not pass.')
    print(result.stdout.decode(), end='')


if __name__ == '__main__':
    main()
