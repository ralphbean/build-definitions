/*
Copyright 2024 Red Hat, Inc.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

package main

import (
	"bytes"
	"flag"
	"os"
	"path/filepath"
	"regexp"
	"strings"

	tektonapi "github.com/tektoncd/pipeline/pkg/apis/pipeline/v1"
	v1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/serializer"
	utilruntime "k8s.io/apimachinery/pkg/util/runtime"
	"k8s.io/cli-runtime/pkg/printers"
	klog "k8s.io/klog/v2"
	"sigs.k8s.io/controller-runtime/pkg/log/zap"
)

func main() {
	var inputTask string
	var outputTask string
	var taskVersion string

	flag.StringVar(&inputTask, "input-task", "", "The location of the llm-compressor-oci-ta task")
	flag.StringVar(&outputTask, "output-task", "", "The location of the llm-compressor-remote-oci-ta task to create")
	flag.StringVar(&taskVersion, "task-version", "", "The version of the task")

	opts := zap.Options{
		Development: true,
	}
	opts.BindFlags(flag.CommandLine)
	klog.InitFlags(flag.CommandLine)
	flag.Parse()
	if inputTask == "" || outputTask == "" || taskVersion == "" {
		println("Must specify input-task, output-task, and task-version params")
		os.Exit(1)
	}

	task := tektonapi.Task{}
	streamFileYamlToTektonObj(inputTask, &task)

	decodingScheme := runtime.NewScheme()
	utilruntime.Must(tektonapi.AddToScheme(decodingScheme))
	convertToRemote(&task, taskVersion)
	y := printers.YAMLPrinter{}
	b := bytes.Buffer{}
	_ = y.PrintObj(&task, &b)
	err := os.MkdirAll(filepath.Dir(outputTask), 0755)
	if err != nil {
		panic(err)
	}
	err = os.WriteFile(outputTask, b.Bytes(), 0660)
	if err != nil {
		panic(err)
	}
}

func decodeBytesToTektonObjbytes(bytes []byte, obj runtime.Object) runtime.Object {
	decodingScheme := runtime.NewScheme()
	utilruntime.Must(tektonapi.AddToScheme(decodingScheme))
	decoderCodecFactory := serializer.NewCodecFactory(decodingScheme)
	decoder := decoderCodecFactory.UniversalDecoder(tektonapi.SchemeGroupVersion)
	err := runtime.DecodeInto(decoder, bytes, obj)
	if err != nil {
		panic(err)
	}
	return obj
}

func streamFileYamlToTektonObj(path string, obj runtime.Object) runtime.Object {
	bytes, err := os.ReadFile(filepath.Clean(path))
	if err != nil {
		panic(err)
	}
	return decodeBytesToTektonObjbytes(bytes, obj)
}

func convertToRemote(task *tektonapi.Task, taskVersion string) {
	builderImage := ""
	syncVolumes := map[string]bool{}
	for _, i := range task.Spec.Volumes {
		if i.Secret != nil || i.ConfigMap != nil {
			syncVolumes[i.Name] = true
		}
	}

	// IMAGE_APPEND_PLATFORM script to inject into steps
	adjustRemoteImage := `if [ "${IMAGE_APPEND_PLATFORM}" == "true" ]; then
  IMAGE="${IMAGE}-${PLATFORM//[^a-zA-Z0-9]/-}"
  export IMAGE
fi
`

	for stepIdx := range task.Spec.Steps {
		step := &task.Spec.Steps[stepIdx]

		// Add IMAGE_APPEND_PLATFORM to non-compress-model steps
		if step.Script != "" && step.Name != "compress-model" {
			scriptHeaderRE := regexp.MustCompile(`^#!(/usr)?(/local)?/bin/(env )?bash(\n)+(set .*\n)*`)
			scriptHeader := scriptHeaderRE.FindString(step.Script)
			ret := ""
			if scriptHeader != "" {
				ret = scriptHeaderRE.ReplaceAllString(step.Script, "")
			} else {
				ret = step.Script
			}
			// If there is a shebang, it is explicitly non-bash, so don't adjust the image
			if !strings.HasPrefix(ret, "#!") {
				if scriptHeader == "" {
					scriptHeader = "#!/bin/bash\nset -e\n"
				}
				ret = scriptHeader + adjustRemoteImage + ret
			}
			step.Script = ret
			continue
		} else if step.Name != "compress-model" {
			continue
		}

		// Found compress-model step - wrap it in remote execution
		podmanArgs := ""
		ret := `#!/bin/bash
set -e
set -o verbose

echo "[$(date --utc -Ins)] Prepare connection"

mkdir -p ~/.ssh
if [ -e "/ssh/error" ]; then
  #no server could be provisioned
  cat /ssh/error
  exit 1
fi
export SSH_HOST=$(cat /ssh/host)

if [ "$SSH_HOST" == "localhost" ] ; then
  IS_LOCALHOST=true
  echo "Localhost detected; running compression in cluster"
elif [ -e "/ssh/otp" ]; then
  curl --cacert /ssh/otp-ca -XPOST -d @/ssh/otp $(cat /ssh/otp-server) >~/.ssh/id_rsa
  echo "" >> ~/.ssh/id_rsa
else
  cp /ssh/id_rsa ~/.ssh
fi

mkdir -p scripts

if ! [[ $IS_LOCALHOST ]]; then
  echo "[$(date --utc -Ins)] Setup VM"

  chmod 0400 ~/.ssh/id_rsa
  export BUILD_DIR=$(cat /ssh/user-dir)
  export SSH_ARGS="-o StrictHostKeyChecking=no -o ServerAliveInterval=60 -o ServerAliveCountMax=10"
  echo "$BUILD_DIR"
  # shellcheck disable=SC2086
  ssh $SSH_ARGS "$SSH_HOST"  mkdir -p "${BUILD_DIR@Q}/workspaces" "${BUILD_DIR@Q}/scripts" "${BUILD_DIR@Q}/volumes"

  echo "[$(date --utc -Ins)] Rsync data"
`
		env := ""

		// Sync workdir to remote
		ret += "\n  rsync -razW /var/workdir/ \"$SSH_HOST:$BUILD_DIR/workspaces/workdir/\""
		podmanArgs += "    -v \"${BUILD_DIR@Q}/workspaces/workdir:/var/workdir:Z\" \\\n"

		// Sync volume mounts from the step
		for _, volume := range step.VolumeMounts {
			if syncVolumes[volume.Name] {
				ret += "\n  rsync -razW " + volume.MountPath + "/ \"$SSH_HOST:$BUILD_DIR/volumes/" + volume.Name + "/\""
				podmanArgs += "    -v \"${BUILD_DIR@Q}/volumes/" + volume.Name + ":" + volume.MountPath + ":Z\" \\\n"
			}
		}
		ret += "\n  rsync -razW  \"$HOME/.docker/\" \"$SSH_HOST:$BUILD_DIR/.docker/\""
		podmanArgs += "    -v \"${BUILD_DIR@Q}/.docker/:/root/.docker:Z\" \\\n"
		ret += "\n  rsync -razW  --mkpath \"/usr/bin/retry\" \"$SSH_HOST:$BUILD_DIR/usr/bin/retry\""
		podmanArgs += "    -v \"${BUILD_DIR@Q}/usr/bin/retry:/usr/bin/retry:Z\" \\\n"
		ret += "\n  rsync -razW  \"/tekton/results/\" \"$SSH_HOST:$BUILD_DIR/results/\""
		podmanArgs += "    -v \"${BUILD_DIR@Q}/results/:/tekton/results:Z\" \\\n"
		ret += "\nfi\n"

		ret += "\n" + adjustRemoteImage

		script := "scripts/script-" + step.Name + ".sh"

		ret += "\ncat >" + script + " <<'REMOTESSHEOF'\n"

		// Extract shebang and set declarations
		reShebang := regexp.MustCompile(`(#!.*\n)(set -.*\n)*`)
		shebangMatch := reShebang.FindString(step.Script)
		if shebangMatch != "" {
			ret += shebangMatch
			step.Script = strings.TrimPrefix(step.Script, shebangMatch)
		} else {
			ret += "#!/bin/bash\nset -o verbose\nset -e\n"
		}

		if step.WorkingDir != "" {
			ret += "cd " + step.WorkingDir + "\n"
		}
		ret += step.Script
		ret += "\nREMOTESSHEOF"
		ret += "\nchmod +x " + script + "\n"
		ret += "\nPODMAN_NVIDIA_ARGS=()"
		ret += "\nif [[ \"$PLATFORM\" == \"linux-g\"* ]]; then"
		ret += "\n    PODMAN_NVIDIA_ARGS+=(\"--device=nvidia.com/gpu=all\" \"--security-opt=label=disable\")"
		ret += "\nfi\n"

		if task.Spec.StepTemplate != nil {
			for _, e := range task.Spec.StepTemplate.Env {
				env += "    -e " + e.Name + "=\"${" + e.Name + "@Q}\" \\\n"
			}
		}
		ret += "\nif ! [[ $IS_LOCALHOST ]]; then"
		ret += "\n  rsync -ra scripts \"$SSH_HOST:$BUILD_DIR\""
		containerScript := "scripts/script-" + step.Name + ".sh"
		for _, e := range step.Env {
			env += "    -e " + e.Name + "=\"${" + e.Name + "@Q}\" \\\n"
		}
		ret += "\n  echo \"[$(date --utc -Ins)] Execute compression via ssh\""
		podmanArgs += "    -v \"${BUILD_DIR@Q}/scripts:/scripts:Z\" \\\n"
		ret += "\n  # shellcheck disable=SC2086"
		ret += "\n  # Please note: all variables below the first ssh line must be quoted with ${var@Q}!"
		ret += "\n  # See https://stackoverflow.com/questions/6592376/prevent-ssh-from-breaking-up-shell-script-parameters"
		ret += "\n  ssh $SSH_ARGS \"$SSH_HOST\" podman run " + env + "" + podmanArgs + "    --user=0 \"${PODMAN_NVIDIA_ARGS[@]@Q}\" --rm \"${BUILDER_IMAGE@Q}\" /" + containerScript + ` "${@@Q}"`

		// Sync back the workdir (contains OUTPUT_DIR)
		ret += "\n  echo \"[$(date --utc -Ins)] Rsync back\""
		ret += "\n  rsync -razW --stats \"$SSH_HOST:$BUILD_DIR/workspaces/workdir/\" /var/workdir/"

		// Sync back volumes
		for _, volume := range step.VolumeMounts {
			if syncVolumes[volume.Name] {
				ret += "\n  rsync -razW --stats \"$SSH_HOST:$BUILD_DIR/volumes/" + volume.Name + "/\" " + volume.MountPath + "/"
			}
		}
		//sync back results
		ret += "\n  rsync -razW --stats \"$SSH_HOST:$BUILD_DIR/results/\" \"/tekton/results/\""

		ret += `
else
  bash ` + containerScript + ` "$@"
fi
echo "Compression on remote host $SSH_HOST finished"

echo "[$(date --utc -Ins)] End remote"`

		for _, i := range strings.Split(ret, "\n") {
			if strings.HasSuffix(i, " ") {
				panic(i)
			}
		}
		step.Script = ret
		builderImage = step.Image
		step.VolumeMounts = append(step.VolumeMounts, v1.VolumeMount{
			Name:      "ssh",
			ReadOnly:  true,
			MountPath: "/ssh",
		})
	}

	task.Name = strings.ReplaceAll(task.Name, "llm-compressor-oci-ta", "llm-compressor-remote-oci-ta")
	task.Spec.Params = append(task.Spec.Params, tektonapi.ParamSpec{Name: "PLATFORM", Type: tektonapi.ParamTypeString, Description: "The platform to build on"})

	falseVar := false
	task.Spec.Volumes = append(task.Spec.Volumes, v1.Volume{
		Name: "ssh",
		VolumeSource: v1.VolumeSource{
			Secret: &v1.SecretVolumeSource{
				SecretName: "multi-platform-ssh-$(context.taskRun.name)",
				Optional:   &falseVar,
			},
		},
	})
	task.Spec.StepTemplate.Env = append(task.Spec.StepTemplate.Env, v1.EnvVar{Name: "BUILDER_IMAGE", Value: builderImage})
	task.Spec.StepTemplate.Env = append(task.Spec.StepTemplate.Env, v1.EnvVar{Name: "PLATFORM", Value: "$(params.PLATFORM)"})

	task.Spec.Params = append(task.Spec.Params, tektonapi.ParamSpec{Name: "IMAGE_APPEND_PLATFORM", Type: tektonapi.ParamTypeString, Description: "Whether to append a sanitized platform architecture on the IMAGE tag", Default: &tektonapi.ParamValue{StringVal: "false", Type: tektonapi.ParamTypeString}})
	task.Spec.StepTemplate.Env = append(task.Spec.StepTemplate.Env, v1.EnvVar{Name: "IMAGE_APPEND_PLATFORM", Value: "$(params.IMAGE_APPEND_PLATFORM)"})
}
