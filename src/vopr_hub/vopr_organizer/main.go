package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"time"
)

var (
	debug_mode            bool
	tigerbeetle_directory string
	repository_url        string
	num_voprs             int
	current_vopr          int
)

type Label struct {
	Name string `json:"name"`
}

type Head struct {
	Label string `json:"label"`
}

type Issue struct {
	Labels []Label `json:"labels"`
	Head   Head    `json:"head"`
}

func set_environment_variables() {
	var found bool
	tigerbeetle_directory, found = os.LookupEnv("TIGERBEETLE_DIRECTORY")
	if !found {
		log_error("Could not find TIGERBEETLE_DIRECTORY environmental variable")
		os.Exit(1)
	} else if tigerbeetle_directory != "" {
		// Ensure there is no trailing slash
		tigerbeetle_directory = strings.TrimRight(tigerbeetle_directory, "/\\")
		log_debug("tigerbeetle_directory set as " + tigerbeetle_directory)
	} else {
		log_error("TIGERBEETLE_DIRECTORY was empty")
		os.Exit(1)
	}

	repository_url, found = os.LookupEnv("REPOSITORY_URL")
	if !found {
		log_error("Could not find REPOSITORY_URL environmental variable")
		os.Exit(1)
	} else if repository_url != "" {
		log_debug("repository_url set as " + repository_url)
	} else {
		log_error("REPOSITORY_URL was empty")
		os.Exit(1)
	}

	num_voprs_str, found := os.LookupEnv("NUM_VOPRS")
	if !found {
		log_error("Could not find NUM_VOPRS environmental variable")
		os.Exit(1)
	} else if num_voprs_str != "" {
		// string to int
		var err error
		num_voprs, err = strconv.Atoi(num_voprs_str)
		if err != nil {
			log_error("unable to convert num_voprs to a an integer value")
			panic(err.Error())
		} else if num_voprs <= 0 {
			log_error("NUM_VOPRS must be an integer greater than 0")
			os.Exit(1)
		}
		log_debug(fmt.Sprintf("num_voprs set as %d", num_voprs))
	} else {
		log_error("NUM_VOPRS was empty")
		os.Exit(1)
	}

	current_vopr_str, found := os.LookupEnv("CURRENT_VOPR")
	if !found {
		log_error("Could not find CURRENT_VOPR environmental variable")
		os.Exit(1)
	} else if current_vopr_str != "" {
		// string to int
		var err error
		current_vopr, err = strconv.Atoi(current_vopr_str)
		if err != nil {
			log_error("unable to convert current_vopr to a an integer value")
			panic(err.Error())
		} else if current_vopr <= 0 {
			log_error("CURRENT_VOPR must be an integer greater than 0")
			os.Exit(1)
		}
		log_debug(fmt.Sprintf("current_vopr set as %d", current_vopr))
	} else {
		log_error("CURRENT_VOPR was empty")
		os.Exit(1)
	}
}

// Fetch available branches from GitHub and checkout the correct branch if it exists.
func checkout_branch(branch string, tigerbeetle_directory string) error {
	// Git commands need to be run with the particular TigerBeetle directory as their working_directory
	fetch_command := exec.Command("git", "fetch", "--all")
	fetch_command.Dir = tigerbeetle_directory
	error := fetch_command.Run()
	if error != nil {
		error_message := fmt.Sprintf("Failed to run git fetch: %s", error.Error())
		log_error(error_message)
		return error
	}

	// Checkout the branch
	checkout_command := exec.Command("git", "checkout", branch)
	checkout_command.Dir = tigerbeetle_directory
	error = checkout_command.Run()
	if error != nil {
		error_message := fmt.Sprintf("Failed to run git checkout: %s", error.Error())
		log_error(error_message)
		return error
	}

	// Inspect the git logs.
	log_command := exec.Command("git", "branch", "--show-current")
	log_command.Dir = tigerbeetle_directory
	log_output, error := log_command.Output()
	if error != nil {
		error_message := fmt.Sprintf("Failed to run git log: %s", error.Error())
		log_error(error_message)
		return error
	}

	// Check the log to determine if the branch has been successfully checked out.
	current_branch := string(log_output[:])
	if !(current_branch == branch) {
		error = fmt.Errorf("Checkout failed")
		return error
	}

	return nil
}

func get_pull_requests() []Issue {
	pull_requests := []Issue{}
	res, err := http.Get(repository_url)
	if err != nil {
		log_error("unable to create get request")
		panic(err.Error())
	}
	body, err := io.ReadAll(res.Body)
	res.Body.Close()
	if res.StatusCode > 299 {
		log_error(fmt.Sprintf("Response failed with status code: %d and\nbody: %s\n", res.StatusCode, body))
		panic(err.Error())
	}
	if err != nil {
		log_error("unable to receive a response from GitHub")
		panic(err.Error())
	}

	err = json.Unmarshal(body, &pull_requests)
	if err != nil {
		log_error("unable to unmarshall json")
		panic(err.Error())
	}
	return pull_requests
}

func get_branch_names(pull_requests []Issue) []string {
	var vopr_branches []string

	for _, element := range pull_requests {
		for _, label := range element.Labels {
			if label.Name == "vopr" {
				// Branches are returned in the format owner:branch_name.
				_, branch_name, found := strings.Cut(element.Head.Label, ":")
				if found && branch_name != "" {
					vopr_branches = append(vopr_branches, branch_name)
				}
				break
			}
		}

		if len(vopr_branches) == num_voprs {
			break
		}
	}
	return vopr_branches
}

func get_vopr_assignments(vopr_branches []string) []string {
	var num_pull_requests = len(vopr_branches)
	var vopr_assignments []string

	if num_pull_requests > 0 {
		// The first VOPR always runs main
		vopr_assignments = append(vopr_assignments, "main")

		// This calculates how many times each PR branch will be assigned to a VOPR.
		var repeats = int((num_voprs - 1) / num_pull_requests)
		// This calculates how many branches will have an additional assignment.
		var remainders = (num_voprs - 1) % num_pull_requests
		i := 1
		branch_index := 0
		for i < num_voprs {
			for j := 0; j < repeats; j++ {
				vopr_assignments = append(vopr_assignments, fmt.Sprintf("%s", vopr_branches[branch_index]))
				i++
			}
			if remainders > 0 {
				vopr_assignments = append(vopr_assignments, fmt.Sprintf("%s", vopr_branches[branch_index]))
				remainders--
				i++
			}
			branch_index++
		}
	} else {
		i := 0
		for i < num_voprs {

			vopr_assignments = append(vopr_assignments, "main")
			i++
		}
	}
	return vopr_assignments
}

func log_error(message string) {
	log_message("error: ", message)
}

func log_info(message string) {
	log_message("info:  ", message)
}

func log_debug(message string) {
	if debug_mode {
		log_message("debug: ", message)
	}
}

// Formats all the log messages and adds a timestamp to them.
func log_message(log_level string, message string) {
	// Gets the current time in UTC and rounds to the nearest second.
	timestamp := time.Now().UTC().Round(time.Second).Format("2006-01-02 15:04:05")
	fmt.Printf("%s %s%s\n", timestamp, log_level, message)
}

func main() {
	// Determine the mode in which to run the VOPR Hub
	flag.BoolVar(&debug_mode, "debug", false, "enable debug logging")
	flag.Parse()

	set_environment_variables()

	// Pull requests will be ordered newest to oldest by default.
	pull_requests := get_pull_requests()

	// Gets the names of branches that have the `vopr` label
	vopr_branches := get_branch_names(pull_requests)

	vopr_assignments := get_vopr_assignments(vopr_branches)
	// TODO remove - debugging
	fmt.Println(vopr_assignments)

	// TODO: index directories from 0
	if current_vopr <= len(vopr_assignments) && current_vopr >= 1 {
		checkout_branch(vopr_assignments[current_vopr-1], fmt.Sprintf("%s%d", tigerbeetle_directory, current_vopr))
	}
}
