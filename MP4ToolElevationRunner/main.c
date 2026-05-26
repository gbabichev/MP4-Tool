/*
 * Small authorization runner used by MP4 Tool to execute the bundled
 * MP4ToolPrivilegedTool after macOS grants administrator permission.
 */

#include <Security/Authorization.h>
#include <Security/AuthorizationTags.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void print_usage(void) {
    fputs("Usage: MP4ToolElevationRunner --prompt <prompt> -- <tool> [args...]\n", stderr);
}

static const char *authorization_message(OSStatus status) {
    switch (status) {
    case errAuthorizationCanceled:
        return "Authorization was cancelled.";
    case errAuthorizationDenied:
        return "Authorization was denied.";
    default:
        return "Authorization failed.";
    }
}

static int forward_privileged_output(FILE *pipe) {
    char buffer[4096];
    char prefix[7] = {0};
    size_t prefix_length = 0;

    while (!feof(pipe)) {
        size_t count = fread(buffer, 1, sizeof(buffer), pipe);
        if (count == 0) {
            break;
        }

        if (prefix_length < sizeof(prefix) - 1) {
            size_t needed = (sizeof(prefix) - 1) - prefix_length;
            size_t copied = count < needed ? count : needed;
            memcpy(prefix + prefix_length, buffer, copied);
            prefix_length += copied;
            prefix[prefix_length] = '\0';
        }

        fwrite(buffer, 1, count, stdout);
    }

    fclose(pipe);

    if (strncmp(prefix, "ERROR\t", 6) == 0) {
        return EXIT_FAILURE;
    }

    if (strncmp(prefix, "OK\n", 3) == 0) {
        return EXIT_SUCCESS;
    }

    fputs("ERROR\tThe privileged tool did not report a result.\n", stdout);
    return EXIT_FAILURE;
}

int main(int argc, char *argv[]) {
    const char *prompt = "MP4 Tool needs administrator permission to finish this operation.";
    int separator_index = -1;

    for (int index = 1; index < argc; index++) {
        if (strcmp(argv[index], "--prompt") == 0) {
            if (index + 1 >= argc) {
                print_usage();
                return EXIT_FAILURE;
            }
            prompt = argv[index + 1];
            index++;
        } else if (strcmp(argv[index], "--") == 0) {
            separator_index = index;
            break;
        }
    }

    if (separator_index < 0 || separator_index + 1 >= argc) {
        print_usage();
        return EXIT_FAILURE;
    }

    const char *tool_path = argv[separator_index + 1];
    char **tool_arguments = &argv[separator_index + 2];

    AuthorizationRef authorization = NULL;
    OSStatus status = AuthorizationCreate(NULL, NULL, kAuthorizationFlagDefaults, &authorization);
    if (status != errAuthorizationSuccess) {
        fprintf(stdout, "ERROR\t%s (%d)\n", authorization_message(status), (int)status);
        return EXIT_FAILURE;
    }

    AuthorizationItem right = { kAuthorizationRightExecute, 0, NULL, 0 };
    AuthorizationRights rights = { 1, &right };
    AuthorizationItem environment_items[] = {
        { kAuthorizationEnvironmentPrompt, (UInt32)strlen(prompt), (void *)prompt, 0 }
    };
    AuthorizationEnvironment environment = { 1, environment_items };
    AuthorizationFlags flags = kAuthorizationFlagInteractionAllowed
        | kAuthorizationFlagPreAuthorize
        | kAuthorizationFlagExtendRights;

    status = AuthorizationCopyRights(authorization, &rights, &environment, flags, NULL);
    if (status != errAuthorizationSuccess) {
        fprintf(stdout, "ERROR\t%s (%d)\n", authorization_message(status), (int)status);
        AuthorizationFree(authorization, kAuthorizationFlagDefaults);
        return EXIT_FAILURE;
    }

    FILE *pipe = NULL;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    status = AuthorizationExecuteWithPrivileges(
        authorization,
        tool_path,
        kAuthorizationFlagDefaults,
        tool_arguments,
        &pipe
    );
#pragma clang diagnostic pop

    if (status != errAuthorizationSuccess) {
        fprintf(stdout, "ERROR\t%s (%d)\n", authorization_message(status), (int)status);
        AuthorizationFree(authorization, kAuthorizationFlagDefaults);
        return EXIT_FAILURE;
    }

    int result = pipe == NULL ? EXIT_SUCCESS : forward_privileged_output(pipe);
    AuthorizationFree(authorization, kAuthorizationFlagDefaults);
    return result;
}
