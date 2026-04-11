// Copyright 2014 Team 254. All Rights Reserved.
// Author: pat@patfairbank.com (Patrick Fairbank)
//
// Methods for configuring a Cisco Catalyst 3850 switch for team VLANs.

package network

import (
	"bufio"
	"bytes"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/Team254/cheesy-arena/model"
)

const (
	switchConfigBackoffDurationSec = 5
	switchConfigPauseDurationSec   = 2
	switchTeamGatewayAddress       = 4
	switchTelnetPort               = 23
)

const (
	red1Vlan  = 10
	red2Vlan  = 20
	red3Vlan  = 30
	blue1Vlan = 40
	blue2Vlan = 50
	blue3Vlan = 60
	teamVlans = 6
)

const switchTeamAccessList = "DS-FMS"

type Switch struct {
	address               string
	port                  int
	password              string
	mutex                 sync.Mutex
	configBackoffDuration time.Duration
	configPauseDuration   time.Duration
	Status                string
}

const DefaultServerIpAddress = "10.0.100.5"

var ServerIpAddress = DefaultServerIpAddress // The DS will try to connect to this address only.

func NewSwitch(address, password string) *Switch {
	return &Switch{
		address:               address,
		port:                  switchTelnetPort,
		password:              password,
		configBackoffDuration: switchConfigBackoffDurationSec * time.Second,
		configPauseDuration:   switchConfigPauseDurationSec * time.Second,
		Status:                "UNKNOWN",
	}
}

// Sets up wired networks for the given set of teams.
func (sw *Switch) ConfigureTeamEthernet(teams [6]*model.Team) error {
	// Make sure multiple configurations aren't being set at the same time.
	sw.mutex.Lock()
	defer sw.mutex.Unlock()
	sw.Status = "CONFIGURING"

	// Remove old team VLANs to reset the switch state.
	var removeTeamVlansCommand strings.Builder
	for vlanIndex := 1; vlanIndex <= teamVlans; vlanIndex++ {
		vlan := vlanIndex * 10
		removeTeamVlansCommand.WriteString(fmt.Sprintf(
			"interface Vlan%d\nno ip address\nno ip access-group %s in\nexit\nno ip dhcp pool dhcp%d\n",
			vlan,
			switchTeamAccessList,
			vlan,
		))
	}
	_, err := sw.runConfigCommand(removeTeamVlansCommand.String())
	if err != nil {
		sw.Status = "ERROR"
		return err
	}
	time.Sleep(sw.configPauseDuration)

	// Create the new team VLANs.
	var addTeamVlansCommand strings.Builder
	addTeamVlan := func(team *model.Team, vlan int) {
		if team == nil {
			return
		}
		teamPartialIp := fmt.Sprintf("%d.%d", team.Id/100, team.Id%100)
		addTeamVlansCommand.WriteString(fmt.Sprintf(
			"ip dhcp excluded-address 10.%s.1 10.%s.19\n"+
				"ip dhcp excluded-address 10.%s.200 10.%s.254\n"+
				"ip dhcp pool dhcp%d\n"+
				"network 10.%s.0 255.255.255.0\n"+
				"default-router 10.%s.%d\n"+
				"lease 7\n"+
				"interface Vlan%d\nip address 10.%s.%d 255.255.255.0\nip access-group %s in\n",
			teamPartialIp,
			teamPartialIp,
			teamPartialIp,
			teamPartialIp,
			vlan,
			teamPartialIp,
			teamPartialIp,
			switchTeamGatewayAddress,
			vlan,
			teamPartialIp,
			switchTeamGatewayAddress,
			switchTeamAccessList,
		))
	}
	addTeamVlan(teams[0], red1Vlan)
	addTeamVlan(teams[1], red2Vlan)
	addTeamVlan(teams[2], red3Vlan)
	addTeamVlan(teams[3], blue1Vlan)
	addTeamVlan(teams[4], blue2Vlan)
	addTeamVlan(teams[5], blue3Vlan)
	if addTeamVlansCommand.Len() > 0 {
		_, err = sw.runConfigCommand(addTeamVlansCommand.String())
		if err != nil {
			sw.Status = "ERROR"
			return err
		}
	}

	// Give some time for the configuration to take before another one can be attempted.
	time.Sleep(sw.configBackoffDuration)

	sw.Status = "ACTIVE"
	return nil
}

// Logs into the switch via Telnet and runs the given command in user exec mode. Reads the output and
// returns it as a string.
func (sw *Switch) runCommand(command string) (string, error) {
	// Open a Telnet connection to the switch.
	conn, err := net.Dial("tcp", net.JoinHostPort(sw.address, strconv.Itoa(sw.port)))
	if err != nil {
		return "", err
	}
	defer conn.Close()

	// Login to the AP, send the command, and log out all at once.
	writer := bufio.NewWriter(conn)
	_, err = writer.WriteString(
		fmt.Sprintf(
			"%s\nenable\n%s\nterminal length 0\n%sexit\n", sw.password, sw.password,
			command,
		),
	)
	if err != nil {
		return "", err
	}
	err = writer.Flush()
	if err != nil {
		return "", err
	}

	// Read the response.
	var reader bytes.Buffer
	_, err = reader.ReadFrom(conn)
	if err != nil {
		if isIgnorableTelnetReadError(err) {
			return reader.String(), nil
		}
		return "", err
	}
	return reader.String(), nil
}

func isIgnorableTelnetReadError(err error) bool {
	if err == nil {
		return false
	}

	if errors.Is(err, io.EOF) || errors.Is(err, net.ErrClosed) || errors.Is(err, syscall.ECONNRESET) || errors.Is(err, syscall.ECONNABORTED) {
		return true
	}

	var netErr *net.OpError
	if errors.As(err, &netErr) {
		if errors.Is(netErr.Err, net.ErrClosed) || errors.Is(netErr.Err, syscall.ECONNRESET) || errors.Is(netErr.Err, syscall.ECONNABORTED) {
			return true
		}
		var syscallErr *os.SyscallError
		if errors.As(netErr.Err, &syscallErr) {
			if errors.Is(syscallErr.Err, syscall.ECONNRESET) || errors.Is(syscallErr.Err, syscall.ECONNABORTED) {
				return true
			}
		}
	}

	errText := strings.ToLower(err.Error())
	return strings.Contains(errText, "connection reset by peer") || strings.Contains(errText, "connection aborted")
}

// Logs into the switch via Telnet and runs the given command in global configuration mode. Reads the output
// and returns it as a string.
func (sw *Switch) runConfigCommand(command string) (string, error) {
	return sw.runCommand(fmt.Sprintf("config terminal\n%send\n", command))
}
