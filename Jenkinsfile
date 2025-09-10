pipeline {
    agent none
    options { timeout(time: 15, unit: 'MINUTES') }

    stages {
        stage('Prepare') {
            agent { label 'linux' }
            steps {
                script {
                    checkout scm
                    env.GIT_COMMIT_MSG = sh (script: 'git log -1 --pretty=%B HEAD', returnStdout: true).trim()
                }
            }
        }
        stage ('Matrix') {
            failFast false
            matrix {
                axes {
                    axis {
                        name 'SOURCE'
                        values 'linux', 'osx', 'win', 'freebsd'
                    }
                    axis {
                        name 'TARGET'
                        values 'x86_64-windows', 'x86_64-linux', 'x86_64-macos', 'x86_64-freebsd', 'aarch64-linux', 'aarch64-macos', 'aarch64-windows', 'arm-linux', 'powerpc64-linux', 'wasm32-wasi', 'aarch64-freebsd', 'riscv64-linux', 'aarch64-ios'
                    }
                }
                //excludes {
                    //exclude {
                        //axis { name 'SOURCE'; values 'win' }
                        //axis { name 'TARGET'; values 'x86_64-windows' }
                    //}
                //}

                agent {
                    label "${SOURCE}"
                }
                stages {
                    stage('Checkout') {
                        steps {
                            checkout scm
                        }
                    }
                    stage('Compile') {
                        steps {
                            script {
                                if (isUnix()) {
                                    sh '$ZIG build -Dtarget=${TARGET}'
                                } else {
                                    bat '%ZIG% build -Dtarget=%TARGET%'
                                }
                            }
                        }
                    }
                    stage('Test') {
                        when {
                            expression {
                                return (
                                    (env.SOURCE == 'linux' && env.TARGET == 'x86_64-linux')
                                    || (env.SOURCE == 'win' && env.TARGET == 'x86_64-windows')
                                    || (env.SOURCE == 'osx' && env.TARGET == 'x86_64-macos')
                                    || (env.SOURCE == 'freebsd' && env.TARGET == 'x86_64-freebsd')
                                )
                            }
                            beforeAgent true
                        }
                        steps {
                            script {
                                if (isUnix()) {
                                    sh '$ZIG build test'
                                } else {
                                    bat '%ZIG% build test'
                                }
                            }
                        }
                    }
                    stage('Benchmark') {
                        when {
                            expression { env.SOURCE == 'linux' && env.TARGET == 'x86_64-linux' }
                            beforeAgent true
                        }
                        steps {
                            sh '$ZIGBENCH anne-profiler'
                        }
                    }
                }
            }
        }
    }
    post {
        always {
            withCredentials([string(credentialsId: 'discord_hook', variable: 'DISCORDHOOK')]) {
                discordSend(
                    webhookURL: DISCORDHOOK,
                    description: env.GIT_COMMIT_MSG,
                    result: currentBuild.currentResult,
                    title: JOB_NAME
                )
            }
        }
    }
}

