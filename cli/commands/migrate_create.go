package commands

import (
	"io/ioutil"
	"os"
	"time"

	"github.com/ghodss/yaml"
	"github.com/hasura/graphql-engine/cli"
	mig "github.com/hasura/graphql-engine/cli/migrate/cmd"
	"github.com/pkg/errors"
	log "github.com/sirupsen/logrus"
	"github.com/spf13/cobra"
	"github.com/spf13/pflag"
	"github.com/spf13/viper"
)

func newMigrateCreateCmd(ec *cli.ExecutionContext) *cobra.Command {
	v := viper.New()
	opts := &migrateCreateOptions{
		EC: ec,
	}

	migrateCreateCmd := &cobra.Command{
		Use:          "create [migration-name]",
		Short:        "Create files required for a migration",
		Long:         "Create sql and yaml files required for a migration",
		SilenceUsage: true,
		Args:         cobra.ExactArgs(1),
		PreRunE: func(cmd *cobra.Command, args []string) error {
			ec.Viper = v
			return ec.Validate()
		},
		RunE: func(cmd *cobra.Command, args []string) error {
			opts.name = args[0]
			opts.EC.Spin("Creating migration files...")
			version, err := opts.run()
			opts.EC.Spinner.Stop()
			if err != nil {
				return err
			}
			opts.EC.Logger.WithFields(log.Fields{
				"version": version,
				"name":    opts.name,
			}).Info("Migrations files created")
			return nil
		},
	}
	f := migrateCreateCmd.Flags()
	opts.flags = f
	f.StringVar(&opts.sqlFile, "sql-from-file", "", "path to an sql file which contains the up actions")
	f.StringVar(&opts.metaDataFile, "metadata-from-file", "", "path to a hasura metadata file to be used for up actions")
	f.BoolVar(&opts.metaDataServer, "metadata-from-server", false, "take metadata from the server and write it as an up migration file")
	f.String("endpoint", "", "http(s) endpoint for Hasura GraphQL Engine")
	f.String("admin-secret", "", "admin secret for Hasura GraphQL Engine")
	f.String("access-key", "", "access key for Hasura GraphQL Engine")
	f.MarkDeprecated("access-key", "use --admin-secret instead")
	migrateCreateCmd.MarkFlagFilename("sql-from-file")
	migrateCreateCmd.MarkFlagFilename("metadata-from-file")

	// need to create a new viper because https://github.com/spf13/viper/issues/233
	v.BindPFlag("endpoint", f.Lookup("endpoint"))
	v.BindPFlag("admin_secret", f.Lookup("admin-secret"))
	v.BindPFlag("access_key", f.Lookup("access-key"))

	return migrateCreateCmd
}

type migrateCreateOptions struct {
	EC *cli.ExecutionContext

	name  string
	flags *pflag.FlagSet

	// Flags
	sqlFile        string
	metaDataFile   string
	metaDataServer bool
}

func (o *migrateCreateOptions) run() (version int64, err error) {
	timestamp := getTime()
	createOptions := mig.New(timestamp, o.name, o.EC.MigrationDir)

	if o.flags.Changed("sql-from-file") {
		// sql-file flag is set
		err := createOptions.SetSQLUpFromFile(o.sqlFile)
		if err != nil {
			return 0, errors.Wrap(err, "cannot set sql file")
		}
	}

	if o.flags.Changed("metadata-from-file") && o.metaDataServer {
		return 0, errors.New("only one metadata type can be set")
	}

	if o.flags.Changed("metadata-from-file") {
		// metadata-file flag is set
		err := createOptions.SetMetaUpFromFile(o.metaDataFile)
		if err != nil {
			return 0, errors.Wrap(err, "cannot set metadata file")
		}
	}

	if o.metaDataServer {
		// create new migrate instance
		migrateDrv, err := newMigrate(o.EC.MigrationDir, o.EC.ServerConfig.ParsedEndpoint, o.EC.ServerConfig.AdminSecret, o.EC.Logger, o.EC.Version)
		if err != nil {
			return 0, errors.Wrap(err, "cannot create migrate instance")
		}

		// fetch metadata from server
		metaData, err := migrateDrv.ExportMetadata()
		if err != nil {
			return 0, errors.Wrap(err, "cannot fetch metadata from server")
		}

		tmpfile, err := ioutil.TempFile("", "metadata")
		if err != nil {
			return 0, errors.Wrap(err, "cannot create tempfile")
		}
		defer os.Remove(tmpfile.Name())

		t, err := yaml.Marshal(metaData)
		if err != nil {
			return 0, errors.Wrap(err, "cannot marshal metadata")
		}
		if _, err := tmpfile.Write(t); err != nil {
			return 0, errors.Wrap(err, "cannot write to temp file")
		}
		if err := tmpfile.Close(); err != nil {
			return 0, errors.Wrap(err, "cannot close tmp file")
		}

		err = createOptions.SetMetaUpFromFile(tmpfile.Name())
		if err != nil {
			return 0, errors.Wrap(err, "cannot parse metadata from the server")
		}
	}

	if !o.flags.Changed("sql-from-file") && !o.flags.Changed("metadata-from-file") && !o.metaDataServer {
		// Set empty data for [up|down].yaml
		createOptions.MetaUp = []byte(`[]`)
		createOptions.MetaDown = []byte(`[]`)
	}

	defer func() {
		if err != nil {
			createOptions.Delete()
		}
	}()
	err = createOptions.Create()
	if err != nil {
		return 0, errors.Wrap(err, "error creating migration files")
	}
	return 0, nil
}

func getTime() int64 {
	startTime := time.Now()
	return startTime.UnixNano() / int64(time.Millisecond)
}
